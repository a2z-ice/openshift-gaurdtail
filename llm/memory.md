# Shared memory for AI assistants (any tool). One line per entry. Newest at the bottom of each section.

## Durable facts (not derivable from the code)
- 2026-09-18: Engine choice = built-in ValidatingAdmissionPolicy (user decision); Kyverno/Gatekeeper rejected to avoid a webhook dependency.
- 2026-09-18: Approvals live as annotations on the target object (no approval CRD) because VAP paramRef.selector validates against ALL matching params and CEL has no clock; TTL is a CronJob.
- 2026-09-18: Git provider = GitHub; SIEM = Splunk (system of record); Loki only for alerting; Teams via Alertmanager msteamsv2 (Workflows webhook).
- 2026-09-19: TRUST MODEL CHANGE (user decision): the GitOps path is pre-approved by the PR ruleset. Argo CD application-controller + applicationset-controller are `gitopsControllers` (exempt); argocd-server (UI/CLI) is NOT. Cluster-side two-person rule applies to out-of-band actions only. Guardrails app now prune: true.
- 2026-09-18: Overlays must reference manifests/base, never manifests/ (kustomize cycle).
- 2026-09-19: Test script is phase-aware (~60 cases incl. RBAC negatives, hardened binding, GitOps path); evidence in ./evidence/. Overlays render 84 objects.

## Open items (close by editing this line with the result + date)
- R3: confirm on the real cluster that VAP evaluates deletes of its own bindings (test case 8). Fallback = RBAC + Argo CD self-heal + GuardrailPolicyModified alert.
- R6: re-check Loki json field names after every Logging operator upgrade (run test-guardrails.sh).
- Placeholders not yet replaced (docs/00-placeholders.md).
- No cluster has been touched from this repo yet; CEL not compiled by an API server yet.

- 2026-09-19: Independent audit (2 reviewers, 59 findings) applied: least-privilege RBAC with Tier A/B, hardened GitOps-only binding (Deny all phases), reaper hardening, alert fixes, script bash-3.2 fixes, AppProject/CR fixes. See docs/16.

- 2026-09-19: Impersonation control (user request): `--as` works only for reads, access reviews and dry-runs. Humans/break-glass off cluster-admin (guardrails-platform-admin + guardrails-impersonator without userextras); markers in userInfo.extra gate exemptions/approver status; policy guardrails-impersonation-dry-run-only. Overlays render 89 objects. docs/17.

## State log (phase changes, test runs, drills; format: date | cluster | event | evidence)
- 2026-09-18 | none | repository created, kustomize/yamllint/bash -n pass locally | local
- 2026-09-18 | none | gap fixes: critical-label-control policy, reaper rejects future timestamps, Argo CD server/appset/operator SAs trusted, 07-hardening-extras added (60 objects per overlay) | local
- 2026-09-19: Deletion lifecycle (docs/19): fixed CEL compile defects D1 (isOlmCsvReplacement) and D2 (isTrustedWriter, broke hardened-binding self-heal) - stray `"` in `>-` blocks; CI now checks CEL literals/brackets. Added `delete-requested-at` (V4-required), `requestTTL` 24h, reaper withdraws stale requests, `guardrails-deletion-tracker` (never denies) + approvers notifications/reminders (`audience="approvers"`), `GuardrailReaperNotRunning`, status/list scripts. 91 objects/overlay, 6 policies, 41 alerts, 76 automated cases. Not yet run on a cluster.
