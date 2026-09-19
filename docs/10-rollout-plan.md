# 10 · Rollout plan

Four phases, each behind a PR that changes only the `guardrails` Application's `spec.source.path`. Nothing is enforced until phase 3, so the first two phases cost nothing but attention.

## Phase 0 – prerequisites (1–2 weeks)

- [ ] Placeholders replaced (docs/00), repository ruleset active (docs/08).
- [ ] IdP groups exist and sync; `gitops-deletion-approvers` ≥ 4 people across ≥ 2 teams; `platform-admins` empty at rest (docs/03).
- [ ] Secrets in the vault: `logging-loki-s3`, `splunk-hec`, SMTP password, Teams webhook URL, `cloud-credentials`.
- [ ] Buckets created with versioning + Object Lock.
- [ ] Operators installed: OpenShift Logging 6.x, Loki Operator, OADP (`manifests/01-audit/operators.yaml`, `06-backup/oadp-dpa.yaml`).
- [ ] Audit profile applied and kube-apiserver rolled (`manifests/01-audit/apiserver-audit.yaml`); disk usage on masters observed for a week.
- [ ] Forwarder Ready, audit lines visible in SIEM and Loki; Alertmanager config installed; synthetic alert received in Teams and email (docs/06).
- [ ] Pre-prod cluster available for `oc apply --dry-run=server` (CI job) and the first real run of `scripts/test-guardrails.sh`.

Rollback: not applicable (nothing enforced).

## Phase 1 – audit only (≥ 1 week)

`manifests/overlays/phase1-audit`: all bindings `validationActions: [Audit]` (rbac-escalation `[Warn, Audit]`).

Apply: merge the PR that sets the app path (or `oc apply --server-side -k manifests/overlays/phase1-audit` once, then let Argo CD own it).

Watch: `CriticalResourceDeleteDenied` (would-have-been-denied), `ArgoCDDirectMutation`, `GuardrailPolicyModified`, `PrivilegedRBACChange`. Every hit is either a workflow the teams must adopt or an identity that needs to be in `gitopsServiceAccounts`/`reaperUsers` (never a human in `exemptUsers`).

Exit criteria:
- VAP status: `Ready=True`, no compile errors (type-check *warnings* are fine).
- `scripts/test-guardrails.sh` on pre-prod: every "deny" case shows the `validation_failure` annotation in the audit log (nothing is blocked yet, so the script itself reports FAIL on deny cases; the annotation is what you check).
- R3 (docs/01) answered: does the policy evaluate deletes of its own bindings? (`oc delete vapb guardrails-critical-delete-named --dry-run=server` produces the audit annotation.)
- Zero unexplained would-have-been-denied events for 7 consecutive days.
- All approvers have run `approve-deletion.sh` once on a scratch object.

Rollback: remove the Application path change; policies stay in Audit (harmless), or `oc delete -k manifests/03-guardrails`.

## Phase 2 – warn (≥ 1 week)

`manifests/overlays/phase2-warn`: `[Warn, Audit]`. Every actor sees the exact denial message as a `Warning:` line in `oc` output, requests still succeed. Argo CD sync results show the warnings.

Exit criteria: zero warnings from CI/CD pipelines and operators for 7 days; teams confirmed they know the workflow; on-call has acknowledged at least one synthetic red alert end to end.

Rollback: PR back to phase 1.

## Phase 3 – enforce deletion guardrail

`manifests/overlays/phase3-enforce`: deletion bindings `[Deny, Audit]`; gitops-only stays `[Audit]`.

Go/no-go checklist (in the change ticket):
- [ ] Phase 2 exit criteria met and signed by platform + security leads.
- [ ] `scripts/test-guardrails.sh` PASS on pre-prod (all 32 cases).
- [ ] Break-glass rehearsal done (docs/09) within the last 30 days.
- [ ] Restore drill done (docs/07) within the last 90 days.
- [ ] On-call roster knows the runbooks.

Apply during a change window; run the smoke test immediately:

```bash
oc delete argocd openshift-gitops -n openshift-gitops --dry-run=server     # denied
scripts/verify-install.sh
```

Rollback: PR back to phase 2 (the PR itself needs 2 approvals; the binding change is applied by Argo CD, which is allowed to mutate). Emergency: break-glass edits the bindings' `validationActions`.

## Phase 4 – GitOps-only mutation (optional but recommended, ≥ 2 weeks after phase 3)

`manifests/overlays/phase4-gitops-only`: `guardrails-gitops-only-mutation` → `[Deny, Audit]`. Humans can no longer hand-edit critical objects (approval annotations excepted).

Exit criteria for entering: zero `ArgoCDDirectMutation` alerts for 14 days.

Rollback: PR back to phase 3.

## Steady state

docs/12: quarterly recertification, quarterly restore drill, monthly synthetic alert, `test-guardrails.sh` after every OCP / Logging / GitOps upgrade.

## Multi-cluster

Repeat per cluster with its own `cluster` label in the forwarder and its own Teams route if desired. With ACM, the `manifests/base` kustomization can be delivered as a `Policy`/`PlacementBinding`; the approval workflow is per cluster (annotations live on the cluster's objects).
