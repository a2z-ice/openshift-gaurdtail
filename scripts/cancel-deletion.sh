#!/usr/bin/env bash
# Withdraw a deletion request (clears request, requester and all approvals). Anyone with patch rights may cancel.
#   ./cancel-deletion.sh <resource> <name> [-n <ns>]
source "$(dirname "$0")/lib.sh"
[[ $# -lt 2 ]] && { usage_target; exit 1; }
parse_target "$@"
oc annotate "${NSARGS[@]}" "$RES" "$NAME" --overwrite "${ANN_REQUEST}-" "${ANN_REQUESTED_BY}-" "${ANN_APPROVALS}-"
green "Deletion request on $RES/$NAME cancelled."
show_state
