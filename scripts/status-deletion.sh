#!/usr/bin/env bash
# Show where a deletion request stands: request, requester, request expiry, every approval with its expiry,
# "have of need, remaining" and whether it can be executed now. Read-only.
#   ./status-deletion.sh <resource> <name> [-n <ns>]
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
[[ $# -lt 2 ]] && { usage_target; exit 1; }
parse_target "$@"
oc get ${NSARGS[@]+"${NSARGS[@]}"} "$RES" "$NAME" -o name >/dev/null || exit 1
show_state
