#!/usr/bin/env bash
# Open a deletion request on a critical resource.
#   ./request-deletion.sh <resource> <name> [-n <ns>] "<CHANGE-TICKET>: <reason>"
# Sets delete-request + delete-requested-by (= your username) + delete-requested-at (now, UTC) and CLEARS any
# previous approvals in the same request, exactly as the admission policy requires (rule V4).
# The request stays open for GuardrailConfig.spec.requestTTL (default 24h); the approvers are notified by
# CriticalDeletionRequested (email + approvers' Teams channel) within about a minute (docs/19).
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
[[ $# -lt 3 ]] && { usage_target; exit 1; }
parse_target "$@"
REASON="${REMAINING[0]+${REMAINING[0]}}"
[[ -z "$REASON" ]] && { red "reason is required, e.g. \"CHG0012345: decommission dev instance\""; exit 1; }
ME="$(whoami_user)"
yellow "Opening deletion request on $RES/$NAME as $ME"
oc annotate ${NSARGS[@]+"${NSARGS[@]}"} "$RES" "$NAME" --overwrite \
  "${ANN_REQUEST}=${REASON}" \
  "${ANN_REQUESTED_BY}=${ME}" \
  "${ANN_REQUESTED_AT}=$(utc_now)" \
  "${ANN_APPROVALS}-"
green "Request recorded. The approvers channel is notified automatically (CriticalDeletionRequested)."
green "$(min_approvers) members of gitops-deletion-approvers (not yourself) must run within $(request_ttl):"
echo "  ./approve-deletion.sh $RES $NAME ${NSARGS[*]+${NSARGS[*]}}"
show_state
