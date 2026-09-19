#!/usr/bin/env bash
# Shared helpers for the guardrail scripts. Source this file; do not run it.
# Works on bash 3.2 (macOS) and 4+/5 (Linux).
set -euo pipefail

PREFIX="guardrails.example.com"
ANN_REQUEST="${PREFIX}/delete-request"
ANN_REQUESTED_BY="${PREFIX}/delete-requested-by"
ANN_REQUESTED_AT="${PREFIX}/delete-requested-at"
ANN_APPROVALS="${PREFIX}/delete-approvals"
LABEL_CRITICAL="${PREFIX}/critical"

red()    { printf '\033[1;31m%s\033[0m\n' "$*"; }
green()  { printf '\033[1;32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[1;33m%s\033[0m\n' "$*"; }

usage_target() {
  cat <<USAGE
Target syntax:  <resource>[.<version>.<group>] <name> [-n <namespace>]
Examples:       argocd openshift-gitops -n openshift-gitops
                application guardrails -n openshift-gitops
                guardrailconfig default
Tier-B kinds (namespaces, CRDs, OLM objects, secrets, serviceaccounts) are break-glass only: see docs/09.
USAGE
}

# parse_target RES NAME [-n NS]  -> sets RES NAME NSARGS (array, may be empty) REMAINING (array, may be empty)
parse_target() {
  RES="${1:?resource}"; NAME="${2:?name}"; shift 2
  NSARGS=()
  REMAINING=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -n|--namespace) NSARGS=(-n "$2"); shift 2 ;;
      *) REMAINING+=("$1"); shift ;;
    esac
  done
}

# expand an array safely under set -u on bash 3.2 (empty arrays are "unbound" there)
ns() { printf '%s\n' ${NSARGS[@]+"${NSARGS[@]}"}; }

whoami_user() { oc whoami; }

# get_ann <annotation-key>  -> value or empty string (never "<no value>")
get_ann() {
  oc get ${NSARGS[@]+"${NSARGS[@]}"} "$RES" "$NAME" \
    -o go-template="{{with .metadata.annotations}}{{with index . \"$1\"}}{{.}}{{end}}{{end}}" 2>/dev/null || true
}

get_label() {
  oc get ${NSARGS[@]+"${NSARGS[@]}"} "$RES" "$NAME" \
    -o go-template="{{with .metadata.labels}}{{with index . \"$1\"}}{{.}}{{end}}{{end}}" 2>/dev/null || true
}

# ---- time helpers (GNU date on Linux, BSD date on macOS)
utc_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
to_epoch() { # strict RFC3339 UTC only (GNU date would accept "" or "yesterday"); 0 = invalid
  [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || { echo 0; return; }
  date -u -d "$1" +%s 2>/dev/null || date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null || echo 0
}
fmt_epoch() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ; }
ttl_seconds() { case "$1" in *h) echo $(( ${1%h} * 3600 )) ;; *m) echo $(( ${1%m} * 60 )) ;; *) echo 0 ;; esac; }
approval_ttl() { local v; v="$(oc get guardrailconfig default -o jsonpath='{.spec.approvalTTL}' 2>/dev/null || true)"; echo "${v:-4h}"; }
request_ttl()  { local v; v="$(oc get guardrailconfig default -o jsonpath='{.spec.requestTTL}' 2>/dev/null || true)"; echo "${v:-24h}"; }

# show_state: the workflow's memory for one object, as the policy and the reaper will see it.
# Prints the request, every approval with its expiry, "have of need, remaining", the request expiry and a verdict.
show_state() {
  local req by at raw need attl rttl now have=0 seen=" " e u t exp verdict
  req="$(get_ann "$ANN_REQUEST")"; by="$(get_ann "$ANN_REQUESTED_BY")"; at="$(get_ann "$ANN_REQUESTED_AT")"
  raw="$(get_ann "$ANN_APPROVALS")"; need="$(min_approvers)"
  attl="$(ttl_seconds "$(approval_ttl)")"; rttl="$(ttl_seconds "$(request_ttl)")"; now="$(date -u +%s)"
  echo "Resource     : $RES/$NAME ${NSARGS[*]+${NSARGS[*]}}"
  echo "critical     : $(get_label "$LABEL_CRITICAL")"
  echo "request      : ${req:-<none>}"
  echo "requested-by : ${by:-<none>}"
  if [[ -n "$at" ]]; then
    t="$(to_epoch "$at")"
    if (( t == 0 )); then exp="invalid timestamp: the reaper will withdraw the request"
    else exp="expires $(fmt_epoch $(( t + rttl ))) ($(( (t + rttl - now) / 60 )) min left)"; fi
    echo "requested-at : $at  -> $exp"
  else
    echo "requested-at : <none>${req:+  -> the reaper will withdraw this request (undated)}"
  fi
  echo "approvals    : ${raw:-<none>}"
  if [[ -n "$raw" ]]; then
    local IFS=','
    for e in $raw; do
      u="${e%%|*}"; t="$(to_epoch "${e#*|}")"
      if (( t == 0 )); then exp="invalid timestamp: will be removed"
      elif (( t > now + 300 )); then exp="future-dated: will be removed"
      elif (( now - t > attl )); then exp="EXPIRED: will be removed by the reaper"
      else exp="valid until $(fmt_epoch $(( t + attl ))) ($(( (t + attl - now) / 60 )) min left)"
        if [[ "$seen" != *" $u "* && "$u" != "$by" ]]; then seen="$seen$u "; have=$((have + 1)); fi
      fi
      echo "               - $u  at ${e#*|}  -> $exp"
    done
    unset IFS
  fi
  if [[ -z "$req" || -z "$by" ]]; then verdict="no open request"
  elif (( have >= need )); then verdict="FULLY APPROVED: a third person (not an approver) may execute"
  else verdict="$(( need - have )) more approval(s) needed"; fi
  echo "progress     : $have of $need valid approvals -> $verdict"
}

min_approvers() { oc get guardrailconfig default -o jsonpath='{.spec.minApprovers}' 2>/dev/null || echo 2; }
