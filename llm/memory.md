# Shared memory for AI assistants (any tool). One line per entry. Newest at the bottom of each section.

## Durable facts (not derivable from the code)
- 2026-09-18: Engine choice = built-in ValidatingAdmissionPolicy (user decision); Kyverno/Gatekeeper rejected to avoid a webhook dependency.
- 2026-09-18: Approvals live as annotations on the target object (no approval CRD) because VAP paramRef.selector validates against ALL matching params and CEL has no clock; TTL is a CronJob.
- 2026-09-18: Git provider = GitHub; SIEM = Splunk (system of record); Loki only for alerting; Teams via Alertmanager msteamsv2 (Workflows webhook).
- 2026-09-18: Argo CD's controller SA is deliberately NOT exempt from the deletion rule (Git-side prunes of critical objects are denied on purpose).
- 2026-09-18: Overlays must reference manifests/base, never manifests/ (kustomize cycle).
- 2026-09-18: Test script has 30 cases; docs reference that number.

## Open items (close by editing this line with the result + date)
- R3: confirm on the real cluster that VAP evaluates deletes of its own bindings (test case 8). Fallback = RBAC + Argo CD self-heal + GuardrailPolicyModified alert.
- R6: re-check Loki json field names after every Logging operator upgrade (run test-guardrails.sh).
- Placeholders not yet replaced (docs/00-placeholders.md).
- No cluster has been touched from this repo yet; CEL not compiled by an API server yet.

## State log (phase changes, test runs, drills; format: date | cluster | event | evidence)
- 2026-09-18 | none | repository created, kustomize/yamllint/bash -n pass locally | local
