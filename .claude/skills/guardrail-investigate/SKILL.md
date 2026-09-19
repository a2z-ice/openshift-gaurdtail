---
name: guardrail-investigate
description: Answer "who deleted / changed / read X, when, from where, was it approved" from the OpenShift audit trail (Loki tenant audit or Splunk). Use for forensics, approval trails, denied attempts, impersonation or break-glass checks.
---

# Audit investigation

Read-only. Never modify cluster objects during an investigation.

1. Identify the object name (and kind/namespace if known) and time window.
2. Run `scripts/audit-query.sh <name>`; it prints the LogQL and Splunk SPL and runs `logcli` if a Loki route + token are available.
3. Otherwise query directly. Loki (console → Observe → Logs, tenant `audit`):
   ```logql
   {log_type="audit"} | json | objectRef_name="<name>" | verb=~"update|patch|delete"
     | line_format "{{.requestReceivedTimestamp}} {{.verb}} {{.objectRef_resource}} by {{.user_username}} imp={{.impersonatedUser_username}} rc={{.responseStatus_code}} :: {{.annotations_guardrails_critical_delete_decision}}"
   ```
   Splunk: `index=openshift_audit objectRef.name="<name>" verb IN (update,patch,delete) | table _time verb user.username impersonatedUser.username responseStatus.code "annotations.guardrails-critical-delete/decision"`
4. Interpret `annotations_guardrails_critical_delete_decision`: `op=… user=… requestedBy=… approvers=a|b approved=true|false exempt=true|false`. `approved=true` on a DELETE = workflow followed; `exempt=true` = break-glass/loopback (must map to an incident); `impersonatedUser_username` non-empty = forged-approval risk, treat as security incident.
5. For request bodies (what changed): add `| verb="patch" | line_format "{{.requestObject}}"` (profile is WriteRequestBodies; secrets bodies are not logged).
6. Report: timeline (timestamp, actor, verb, result), whether the two-person rule was satisfied, anomalies. Full cookbook: `docs/02-audit-logging.md` §Investigation cookbook.
