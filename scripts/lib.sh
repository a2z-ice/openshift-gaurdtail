#!/usr/bin/env bash
# Shared helpers for the guardrail scripts. Source this file; do not run it.
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
                namespace openshift-gitops
                crd applications.argoproj.io
USAGE
}

# parse_target RES NAME [-n NS]  -> sets RES NAME NSARGS
parse_target() {
  RES="${1:?resource}"; NAME="${2:?name}"; shift 2
  NSARGS=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -n|--namespace) NSARGS=(-n "$2"); shift 2 ;;
      *) break ;;
    esac
  done
  REMAINING=("$@")
}

whoami_user() { oc whoami; }

get_ann() { # get_ann <annotation-key>
  oc get "${NSARGS[@]}" "$RES" "$NAME" -o go-template="{{with .metadata.annotations}}{{index . \"$1\"}}{{end}}" 2>/dev/null || true
}

show_state() {
  echo "Resource     : $RES/$NAME ${NSARGS[*]:-}"
  echo "critical     : $(oc get "${NSARGS[@]}" "$RES" "$NAME" -o go-template="{{with .metadata.labels}}{{index . \"$LABEL_CRITICAL\"}}{{end}}" 2>/dev/null || true)"
  echo "request      : $(get_ann "$ANN_REQUEST")"
  echo "requested-by : $(get_ann "$ANN_REQUESTED_BY")"
  local raw; raw="$(get_ann "$ANN_APPROVALS")"
  echo "approvals    : ${raw:-<none>}"
  if [[ -n "$raw" ]]; then
    IFS=',' read -r -a ENTRIES <<< "$raw"
    for e in "${ENTRIES[@]}"; do echo "               - ${e%%|*}  at ${e#*|}"; done
  fi
}

min_approvers() { oc get guardrailconfig default -o jsonpath='{.spec.minApprovers}' 2>/dev/null || echo 2; }
