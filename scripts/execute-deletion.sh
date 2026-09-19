#!/usr/bin/env bash
# Perform the deletion once approvals are in place.
#   ./execute-deletion.sh <resource> <name> [-n <ns>] [--yes]
# The admission policy does the real check; this script only pre-validates and shows the audit query afterwards.
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
[[ $# -lt 2 ]] && { usage_target; exit 1; }
parse_target "$@"
AUTO=false; for a in ${REMAINING[@]+"${REMAINING[@]}"}; do [[ "$a" == "--yes" ]] && AUTO=true; done
ME="$(whoami_user)"
MIN="$(min_approvers)"
RAW="$(get_ann "$ANN_APPROVALS")"
REQ_BY="$(get_ann "$ANN_REQUESTED_BY")"
show_state
COUNT=0; SEEN=" "
if [[ -n "$RAW" ]]; then
  IFS=',' read -r -a ENTRIES <<< "$RAW"
  for e in "${ENTRIES[@]}"; do
    u="${e%%|*}"
    if [[ "$SEEN" != *" $u "* ]]; then SEEN="$SEEN$u "; COUNT=$((COUNT+1)); fi
    [[ "$u" == "$ME" ]] && red "WARNING: you ($ME) are an approver; the policy will deny unless executorMayBeApprover=true"
  done
fi
[[ $COUNT -lt $MIN ]] && { red "Only $COUNT distinct approvals, $MIN required. Deletion will be denied."; exit 1; }
[[ -z "$REQ_BY" ]] && { red "No delete-request present. Deletion will be denied."; exit 1; }
case "$RES" in
  namespace|namespaces|ns|project|projects|crd|customresourcedefinition|customresourcedefinitions*|secret|secrets|subscription*|clusterserviceversion*|csv|operatorgroup*)
    red "$RES is a Tier-B kind: not deletable through the workflow roles (break-glass only, see docs/09)."; exit 1 ;;
esac
if [[ "$AUTO" != "true" ]]; then
  read -r -p "Delete $RES/$NAME ${NSARGS[*]+${NSARGS[*]}} NOW as $ME? Type the resource name to confirm: " CONFIRM
  [[ "$CONFIRM" == "$NAME" ]] || { yellow "aborted"; exit 1; }
fi
if oc delete ${NSARGS[@]+"${NSARGS[@]}"} "$RES" "$NAME" --wait=false; then
  green "Deletion accepted. Expect CriticalResourceDeleted (email + Teams) within ~60s."
  echo "Audit trail (Loki / logcli):"
  echo "  logcli query --org-id=audit '{log_type=\"audit\"} | json | objectRef_name=\"$NAME\" | verb=~\"patch|update|delete\"' --since=24h"
  echo "Splunk:"
  echo "  index=openshift_audit objectRef.name=\"$NAME\" verb IN (patch, update, delete) | table _time user.username verb annotations.*"
else
  red "Deletion was DENIED by the guardrail (see message above)."
  exit 1
fi
