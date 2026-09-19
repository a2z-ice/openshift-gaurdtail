#!/usr/bin/env bash
# Record YOUR approval on an open deletion request.
#   ./approve-deletion.sh <resource> <name> [-n <ns>] [--yes]
# Appends "<your-username>|<UTC timestamp>" to delete-approvals. The policy rejects anything else
# (approving twice, approving your own request, changing other fields, not being in the approver group).
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
[[ $# -lt 2 ]] && { usage_target; exit 1; }
parse_target "$@"
AUTO=false; for a in ${REMAINING[@]+"${REMAINING[@]}"}; do [[ "$a" == "--yes" ]] && AUTO=true; done
ME="$(whoami_user)"
REQ_BY="$(get_ann "$ANN_REQUESTED_BY")"
REQ="$(get_ann "$ANN_REQUEST")"
[[ -z "$REQ_BY" || -z "$REQ" ]] && { red "No open deletion request on $RES/$NAME. The requester must run request-deletion.sh first."; exit 1; }
[[ "$REQ_BY" == "$ME" ]] && { red "You opened this request ($ME); you cannot approve it."; exit 1; }
echo "Request by   : $REQ_BY"
echo "Reason       : $REQ"
show_state
if [[ "$AUTO" != "true" ]]; then
  read -r -p "Approve deletion of $RES/$NAME as $ME? Type 'approve' to continue: " CONFIRM
  [[ "$CONFIRM" == "approve" ]] || { yellow "aborted"; exit 1; }
fi
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
CUR="$(get_ann "$ANN_APPROVALS")"
NEW="${CUR:+${CUR},}${ME}|${TS}"
oc annotate ${NSARGS[@]+"${NSARGS[@]}"} "$RES" "$NAME" --overwrite "${ANN_APPROVALS}=${NEW}"
green "Approval recorded at $TS"
show_state
