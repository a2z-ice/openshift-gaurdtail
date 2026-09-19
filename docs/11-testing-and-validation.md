# 11 · Testing and validation

## Static (CI, every PR)

`.github/workflows/policy-ci.yaml`: yamllint → `kustomize build` (base + 4 overlays) → kubeconform (Kubernetes 1.34 schemas, CRDs from the datree catalog, unknown CRDs skipped) → guardrail invariants → shellcheck → optional `oc apply --dry-run=server` on pre-prod (catches CEL compile errors: the API server compiles every expression on admission of the policy object).

Locally:

```bash
yamllint -c .yamllint manifests
for o in manifests/base manifests/overlays/*; do kustomize build "$o" >/dev/null && echo "OK $o"; done
```

## Policy compile and readiness (after apply)

```bash
oc get validatingadmissionpolicy -l app.kubernetes.io/part-of=guardrails \
  -o custom-columns=NAME:.metadata.name,READY:'.status.conditions[?(@.type=="Ready")].status',WARN:'.status.typeChecking.expressionWarnings[*].fieldRef'
oc get validatingadmissionpolicy guardrails-critical-delete -o jsonpath='{.status.conditions}' | python3 -m json.tool
```

`Ready=True` is required. `expressionWarnings` mentioning undefined fields (`spec`, `data`, `rules`, `users`…) are expected because the policy matches many kinds.

## Functional matrix (`scripts/test-guardrails.sh`)

Creates namespace `guardrails-test` with a critical-labelled ConfigMap and runs 30 cases. Real critical objects are touched only with `--dry-run=server`, which still goes through admission. Two identity modes: impersonation (fast, raises `ImpersonationUsed` on purpose) or four real kubeconfigs (sign-off run).

| # | Case | Expected (phase 3) |
|---|---|---|
| 1 | delete non-critical ConfigMap | allow |
| 2 | cluster-admin deletes critical ConfigMap | **deny** |
| 3 | cluster-admin removes critical label | **deny** |
| 4 | cluster-admin dry-run delete `ArgoCD/openshift-gitops` | **deny** |
| 5 | cluster-admin dry-run delete namespace `openshift-gitops` | **deny** |
| 6 | cluster-admin dry-run delete CRD `applications.argoproj.io` | **deny** |
| 7 | cluster-admin dry-run delete `GuardrailConfig/default` | **deny** |
| 8 | cluster-admin dry-run delete policy binding | **deny** (or RBAC-forbidden; see R3) |
| 9 | cluster-admin dry-run delete approver group | **deny** |
| 10 | admin writes two approvals directly | **deny** |
| 11 | requester sets requested-by to someone else | **deny** |
| 12 | approver approves before a request exists | **deny** |
| 13 | requester opens a request | allow |
| 14 | requester approves own request | **deny** |
| 15 | approver1 approves under approver2's name | **deny** |
| 16 | approver1 approves and changes `data` in one patch | **deny** |
| 17 | approver1 approves | allow |
| 18 | executor deletes with one approval | **deny** |
| 19 | approver1 approves twice | **deny** |
| 20 | approver2 replaces the list instead of appending | **deny** |
| 21 | approver2 appends | allow |
| 22 | approver1 (an approver) executes | **deny** |
| 23 | requester edits the reason after approvals | **deny** |
| 24 | executor deletes with two approvals | **allow** → `CriticalResourceDeleted` in Teams + email |
| 25–28 | cancel path: request, approve, cancel by a third party, delete after cancel | allow / allow / allow / **deny** |
| 29–30 | reaper SA tries to add an approval / removes all approvals | **deny** / allow |

Run:

```bash
# impersonation mode (default) – from a cluster-admin session
scripts/test-guardrails.sh
# sign-off mode – four real users
IMPERSONATE=false KUBECONFIG_REQUESTER=~/.kube/req KUBECONFIG_APPROVER1=~/.kube/a1 KUBECONFIG_APPROVER2=~/.kube/a2 KUBECONFIG_EXECUTOR=~/.kube/ex \
  REQ_USER=req@example.com APP1=a1@example.com APP2=a2@example.com EXEC_USER=ex@example.com scripts/test-guardrails.sh
```

Output: PASS/FAIL per case and `evidence-<ts>.log` with the full API responses; attach it to the change ticket.

In phase 1 (Audit only) the "deny" cases *succeed* by design; the proof is the audit annotation:

```logql
{log_type="audit"} | json | objectRef_namespace="guardrails-test" | annotations_validation_policy_admission_k8s_io_validation_failure=~".+"
```

## Alert delivery

1. Synthetic via `amtool alert add` (docs/06) → Teams card + email ≤ 10 s.
2. Real: case 24 of the matrix → `CriticalResourceDeleted` ≤ 60 s; cases 2–9 → `CriticalResourceDeleteDenied`; the run itself → `ImpersonationUsed` (impersonation mode).
3. Pipeline health: scale the collector to zero for 12 minutes (`oc -n openshift-logging patch clusterlogforwarder audit-forwarder --type merge -p '{"spec":{"managementState":"Unmanaged"}}'` then `oc -n openshift-logging delete ds audit-forwarder`; **needs approvals in phase 3** because the forwarder is critical, which is itself a good test) → `AuditLogIngestionStalled`. Restore with `managementState: Managed`.
4. Argo CD availability: `oc -n openshift-gitops scale statefulset openshift-gitops-application-controller --replicas=0` (the operator will scale it back; expect `ArgoCDApplicationControllerMissing` within 2–3 min, then resolved).

Record timestamps: audit `requestReceivedTimestamp` → alert `startsAt` → Teams post time. Target ≤ 60 s end to end.

## Git-side

- Open a PR that deletes `manifests/03-guardrails/vap-critical-delete-bindings.yaml`: CI invariant fails; even if merged, Argo CD does not prune (`prune: false`); a manual prune sync is denied and alerted (docs/05).
- Open a PR adding a human to `exemptUsers`: CI invariant fails; CODEOWNERS requires security review.

## Recovery

Quarterly restore drill (docs/07) and an annual full "Argo CD cold start" rehearsal on pre-prod with timing.

## Evidence to keep (per run)

`evidence-*.log`, screenshots/exports of the Teams posts and emails, the LogQL/SPL output for the deleted test object, `scripts/verify-install.sh` output, the change ticket. Store with the compliance records (docs/12).
