#!/usr/bin/env bash
# Shared helpers for the guardrail scripts. Source this file; do not run it.
# Works on bash 3.2 (macOS) and 4+/5 (Linux).
set -euo pipefail

PREFIX="guardrails.example.com"
ANN_REQUEST="${PREFIX}/delete-request"
ANN_REQUESTED_BY="${PREFIX}/delete-requested-by"
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

show_state() {
  echo "Resource     : $RES/$NAME ${NSARGS[*]+${NSARGS[*]}}"
  echo "critical     : $(get_label "$LABEL_CRITICAL")"
  echo "request      : $(get_ann "$ANN_REQUEST")"
  echo "requested-by : $(get_ann "$ANN_REQUESTED_BY")"
  local raw; raw="$(get_ann "$ANN_APPROVALS")"
  echo "approvals    : ${raw:-<none>}"
  if [[ -n "$raw" ]]; then
    local IFS=','
    for e in $raw; do echo "               - ${e%%|*}  at ${e#*|}"; done
  fi
}

min_approvers() { oc get guardrailconfig default -o jsonpath='{.spec.minApprovers}' 2>/dev/null || echo 2; }
