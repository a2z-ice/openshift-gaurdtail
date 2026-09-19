#!/usr/bin/env bash
# Open a deletion request on a critical resource.
#   ./request-deletion.sh <resource> <name> [-n <ns>] "<CHANGE-TICKET>: <reason>"
# Sets delete-request + delete-requested-by (= your username) and CLEARS any previous approvals,
# exactly as the admission policy requires (rule V4).
source "$(dirname "$0")/lib.sh"
[[ $# -lt 3 ]] && { usage_target; exit 1; }
parse_target "$@"
REASON="${REMAINING[0]:-}"
[[ -z "$REASON" ]] && { red "reason is required, e.g. \"CHG0012345: decommission dev cluster instance\""; exit 1; }
ME="$(whoami_user)"
yellow "Opening deletion request on $RES/$NAME as $ME"
oc annotate "${NSARGS[@]}" "$RES" "$NAME" --overwrite \
  "${ANN_REQUEST}=${REASON}" \
  "${ANN_REQUESTED_BY}=${ME}" \
  "${ANN_APPROVALS}-"
green "Request recorded. Ask $(min_approvers) members of gitops-deletion-approvers (not yourself) to run:"
echo "  ./approve-deletion.sh $RES $NAME ${NSARGS[*]:-}"
show_state
