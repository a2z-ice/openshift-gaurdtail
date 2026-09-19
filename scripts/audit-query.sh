#!/usr/bin/env bash
# Who did what to <name>? Prints ready-to-run Loki (logcli) and Splunk queries and, if logcli + a route are
# available, runs the Loki one.
#   ./audit-query.sh <name> [--since 24h]
set -euo pipefail
NAME="${1:?object name}"; SINCE="${3:-24h}"
LOKI_ROUTE="$(oc get route -n openshift-logging logging-loki -o jsonpath='{.spec.host}' 2>/dev/null || true)"
Q="{log_type=\"audit\"} | json | objectRef_name=\"${NAME}\" | verb=~\"create|update|patch|delete\" | line_format \"{{.requestReceivedTimestamp}} {{.verb}} {{.objectRef_resource}} {{.objectRef_namespace}}/{{.objectRef_name}} by {{.user_username}} imp={{.impersonatedUser_username}} code={{.responseStatus_code}} decision={{.annotations_guardrails_critical_delete_decision}}\""
echo "LogQL:"; echo "  $Q"
echo
echo "Splunk SPL:"
echo "  index=openshift_audit objectRef.name=\"${NAME}\" verb IN (create,update,patch,delete)"
echo "  | table _time verb objectRef.resource objectRef.namespace objectRef.name user.username impersonatedUser.username responseStatus.code annotations.guardrails-critical-delete/decision"
echo
if command -v logcli >/dev/null && [[ -n "$LOKI_ROUTE" ]]; then
  echo "Running against https://${LOKI_ROUTE} (tenant audit) ..."
  LOKI_ADDR="https://${LOKI_ROUTE}/api/logs/v1/audit" LOKI_BEARER_TOKEN="$(oc whoami -t)" \
    logcli query --org-id=audit --since="$SINCE" --limit=200 "$Q"
fi
