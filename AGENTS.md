# AGENTS.md — operating guide for AI assistants (Claude Code, Codex, Cursor, Copilot, Gemini, others)

Read this file first. It is designed so you rarely need anything else. Load a document from the **Read map** only when the task needs it. Skills for common tasks live in `.claude/skills/*/SKILL.md` (open Agent Skills format; any tool can read them as plain instructions).

## What this repository is

Production controls for an OpenShift 4.21 cluster running OpenShift GitOps (Argo CD):
audit trail (API-server audit → SIEM + Loki), a **two-person rule for deleting critical resources** enforced by a built-in `ValidatingAdmissionPolicy` (CEL) that applies to cluster-admin too, red alerts to **email + Microsoft Teams**, backups, and a phased rollout. Everything is applied through Argo CD from `manifests/overlays/<phase>`.

## Hard rules for assistants

1. **Never weaken the guardrail silently.** Do not add humans to `exemptUsers`, lower `minApprovers` below 2, set `executorMayBeApprover: true`, remove `Deny` from a phase-3/4 binding, add `resources-finalizer.argocd.argoproj.io` or `prune: true` to `manifests/04-argocd/application-guardrails.yaml`. If asked, explain the consequence and require an explicit, written decision; CI (`.github/workflows/policy-ci.yaml`) blocks these anyway.
2. **Never bypass the workflow.** A critical deletion is `request → approve ×2 → execute` by three different humans (`scripts/*.sh`). Do not suggest `--as` impersonation, `kubeadmin`, `system:admin`, the break-glass token, patching finalizers, or editing `validationActions` to get a deletion through. Those are P1 security alerts by design.
3. **No secrets in Git.** SMTP password, Teams webhook URL (`sig=`), Loki S3 keys, Splunk HEC token, OADP credentials stay `REPLACE_*` placeholders; real values come from the vault.
4. **Every manifest change is a PR** with two approvals (ruleset has no bypass). Do not `oc apply` manifests to a cluster by hand except the phase-1 bootstrap or a documented break-glass.
5. **Validate before proposing**: `kustomize build` for base + all overlays, `yamllint -c .yamllint manifests`, `bash -n scripts/*.sh`. Keep `docs/04` rule numbering (V1–V4) in sync with `manifests/03-guardrails/vap-critical-delete.yaml`.
6. **Record state** you change or learn in `llm/memory.md` (current phase, last test run, open risks). Keep entries one line each.
7. Placeholders (`guardrails.example.com`, `example-org`, `example.com` addresses) are intentional until the user runs the replacement in `docs/00-placeholders.md`. Do not "fix" them.

## Facts (memorise; do not re-derive)

| Item | Value |
|---|---|
| Critical marker | label `guardrails.example.com/critical: "true"`; some kinds protected by name (namespaces `openshift-gitops*`, `guardrails-system`; CRDs in `argoproj.io`, `guardrails.example.com`, `loki.grafana.com`, `observability.openshift.io`, `velero.io`, `oadp.openshift.io`; objects named `guardrails-*`; `ArgoCD/openshift-gitops`; OLM objects in `openshift-gitops-operator`; `APIServer/cluster`; the approver groups) |
| Annotations | `guardrails.example.com/delete-request` = `"<ticket>: <reason>"`; `…/delete-requested-by` = requester's own username; `…/delete-approvals` = `user\|RFC3339Z,user\|RFC3339Z` (append one entry per approver) |
| Rule | ≥ `minApprovers` (2) distinct approvers ∈ `gitops-deletion-approvers`, none = requester, executor ∉ approvers, request present, nothing else changed in the same update, approvals wiped if the request changes |
| Param object | `GuardrailConfig/default` (`guardrails.example.com/v1alpha1`) |
| Exempt identities | `system:apiserver`, `system:serviceaccount:guardrails-system:breakglass` only |
| Allowed mutators of critical objects | `system:serviceaccount:openshift-gitops:openshift-gitops-argocd-application-controller` (not exempt from deletion) |
| Groups | `platform-admins` (JIT cluster-admin), `gitops-deletion-approvers`, `gitops-deletion-requesters`, `gitops-operators`, `auditors` |
| Approval TTL | 4h, enforced by CronJob `guardrails-system/approval-reaper` (remove-only) |
| Phases | 1 audit `[Audit]` → 2 warn `[Warn,Audit]` → 3 enforce `[Deny,Audit]` → 4 gitops-only mutation `[Deny,Audit]`; selected by `spec.source.path` of Argo CD app `openshift-gitops/guardrails` |
| Alerts | `guardrail="true"` label; critical → email + Teams (`group_wait 0s`, repeat 30m); key names: `CriticalResourceDeleted`, `CriticalResourceDeleteDenied`, `GuardrailPolicyModified`, `ImpersonationUsed`, `BreakGlassUsed`, `ArgoCDApplicationControllerMissing`, `AuditLogIngestionStalled` |
| Audit fields (Loki json) | `verb`, `user_username`, `impersonatedUser_username`, `objectRef_resource/_namespace/_name`, `responseStatus_code`, `annotations_guardrails_critical_delete_decision`, `annotations_validation_policy_admission_k8s_io_validation_failure` |
| Versions verified | OCP 4.21 = K8s 1.34, Alertmanager 0.29.0 (`msteamsv2_configs`), GitOps 1.19+, Logging 6.x (`observability.openshift.io/v1`), Loki Operator 6.x, OADP 1.5 |

## Commands

```bash
# workflow (three different humans)
scripts/request-deletion.sh <res> <name> [-n ns] "CHG…: reason"
scripts/approve-deletion.sh <res> <name> [-n ns]          # approver 1, then approver 2
scripts/execute-deletion.sh <res> <name> [-n ns]          # executor
scripts/cancel-deletion.sh  <res> <name> [-n ns]
# health / evidence
scripts/verify-install.sh
scripts/test-guardrails.sh                                # 30 cases, scratch ns guardrails-test
scripts/audit-query.sh <object-name>                      # prints LogQL + SPL, runs logcli if available
# local validation
for o in manifests/base manifests/overlays/*; do kustomize build "$o" >/dev/null; done; yamllint -c .yamllint manifests
# smoke test on a cluster (must be denied in phase 3)
oc delete argocd openshift-gitops -n openshift-gitops --dry-run=server
```

## Read map (open only what the task needs)

| Task | Read |
|---|---|
| Run/explain a deletion | `.claude/skills/guardrail-delete/SKILL.md` → `docs/09-runbooks.md` §Request |
| "Who deleted / changed X?" | `.claude/skills/guardrail-investigate/SKILL.md` → `docs/02-audit-logging.md` §Cookbook |
| Alert fired, what now | `.claude/skills/guardrail-incident/SKILL.md` → `docs/09-runbooks.md` §Respond |
| Change a policy rule | `manifests/03-guardrails/vap-critical-delete.yaml` + `docs/04-deletion-guardrails.md` |
| Add/remove a critical object | `docs/04` §Adding; label in Git |
| Move to next phase | `.claude/skills/guardrail-rollout/SKILL.md` → `docs/10-rollout-plan.md` |
| Alert routing / Teams / email | `manifests/05-alerting/alertmanager-main.yaml`, `docs/06` |
| Audit profile / forwarding | `manifests/01-audit/*`, `docs/02` |
| RBAC / groups / break-glass | `manifests/02-rbac/*`, `docs/03` |
| Backups / restore | `manifests/06-backup/*`, `docs/07` |
| Argo CD specifics | `manifests/04-argocd/*`, `docs/05` |
| What is NOT covered | `docs/01-threat-model.md` §Residual-risk register |
| Machine-readable facts | `llm/context.yaml` |
| Shared state / memory | `llm/memory.md` |
