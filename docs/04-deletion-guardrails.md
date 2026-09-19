# 04 · Deletion guardrails: the two-person rule in kube-apiserver

## Scope: out-of-band changes only

The GitOps path is pre-approved: a change merged through the repository ruleset (two reviewers, code owners) and applied by the Argo CD application-controller or ApplicationSet controller (`GuardrailConfig.spec.gitopsControllers`) is exempt from every rule below. Git-driven deletions of critical objects are alerted as `GitOpsCriticalDeletionApplied` so they can be correlated with the PR. Everything else that touches a critical object directly, whoever the actor is (humans with `oc`/console, the Argo CD UI/CLI acting as `argocd-server`, other controllers, cluster-admin), is out of band and subject to the two-person rule.

## Why ValidatingAdmissionPolicy (VAP)

| Option | Verdict |
|---|---|
| **ValidatingAdmissionPolicy (chosen)** | Built into kube-apiserver (GA since Kubernetes 1.30; OCP 4.21 = 1.34). Evaluated in-process for every request, including `system:masters`. No webhook to be down, no operator to be uninstalled, no pod to be scaled to zero. Policy = declarative CEL, reviewable in a PR. |
| Kyverno / Gatekeeper | Same logic possible, plus a clock, but adds a webhook whose availability and RBAC become part of the attack surface (delete the webhook configuration → control gone). Acceptable as a *second* engine; not needed. |
| RBAC only | Cannot express "delete only with approvals"; anyone with `delete` deletes. |
| Finalizers only | A finalizer does not stop the DELETE (object goes to Terminating); the controller that removes it can be bypassed by patching finalizers; no approval concept. |

## Mechanism: approval on the target object

A deletion needs three annotations on the object being deleted. Because they live **on the object**, the approval trail is in the audit log of that very object, no separate controller or CRD instance is needed, and the object disappears with its approvals when the deletion succeeds.

| Annotation (`guardrails.example.com/`) | Written by | Content |
|---|---|---|
| `delete-request` | requester | `"<change-ticket>: <reason>"` |
| `delete-requested-by` | requester | requester's own username (enforced) |
| `delete-approvals` | each approver, one at a time | `"<user>\|<RFC3339 UTC>,<user>\|<RFC3339 UTC>"` |

Plus the marker that makes an object critical: label `guardrails.example.com/critical: "true"`. Objects that cannot be labelled reliably before installation (namespaces, CRDs, the policies themselves, groups, `APIServer/cluster`, the `ArgoCD` CR, OLM objects) are protected **by name** inside the policy (`variables.nameCritical`).

Parameters (`GuardrailConfig/default`): `minApprovers` (2), `executorMayBeApprover` (false → three people), `approverGroups`, `requesterGroups`, `exemptUsers` (API-server loopback + break-glass SA), `reaperUsers`, `gitopsServiceAccounts`, `approvalTTL` (4h), `runbookURL`.

## The policy, rule by rule (`manifests/03-guardrails/vap-critical-delete.yaml`)

All rules are evaluated on the **pre-request state** (`oldObject`), so nothing can be changed and exploited in the same request.

| Rule | Operation | Passes when | Blocks |
|---|---|---|---|
| **V1** | DELETE | not critical, or caller exempt, or `deletionApproved` | every deletion without the two-person rule, by anyone |
| **V2** | UPDATE | the `critical=true` label stays, or `deletionApproved` | "unlabel, then delete" |
| **V3** | UPDATE | approvals unchanged; **or** cleared entirely (cancel); **or** reaper removing entries only; **or** exactly one entry appended whose user == caller, caller ∈ approver group, caller ∉ existing approvers, caller ≠ requester, a request exists, request unchanged, and nothing else in the object changed | forged/duplicate/third-party approvals, approving your own request, smuggling a spec change into an approval |
| **V4** | UPDATE | request unchanged; **or** approvals empty and (request cleared, or requested-by == caller ∧ caller ∈ requester/approver groups ∧ reason non-empty) and nothing else changed | opening a request in someone else's name, editing the reason after approvals (which would let approvals apply to a different justification) |

`deletionApproved` := request present ∧ requested-by present ∧ `distinct(approvers) ≥ minApprovers` ∧ requester ∉ approvers ∧ (executor ∉ approvers unless `executorMayBeApprover`).

`auditAnnotations.decision` is stamped on every evaluated request (allowed or denied): `op=… user=… groups=… requestedBy=… approvers=… approved=… exempt=…`. The alerts key off it.

Design notes:

- **`payloadUnchanged`** compares labels, `spec`, `data`, `binaryData`, `immutable`, `rules`, `aggregationRule`, `subjects`, `roleRef`, `users`, `webhooks`, Application `operation`, `metadata.finalizers` and `metadata.ownerReferences`; an approval write that touches any of them is denied.

- **Exemptions are explicit**: `exemptUsers` (`system:apiserver`, the break-glass SA) and `gitopsControllers` (the two Argo CD controllers, the Git path). OLM may delete a superseded CSV during an operator upgrade (`olmServiceAccounts`, V1 clause). Not the garbage collector, not the namespace controller, not `argocd-server`. A controller whose delete is denied simply retries and the denial is alerted, which is the desired behaviour for a critical object.
- **No clock in CEL** → TTL is enforced by the reaper CronJob (`reaper-cronjob.yaml`, every 10 min); the policy lets that identity only *remove* entries. The reaper also removes entries whose timestamp is more than 5 minutes in the **future** or unparseable, so an approver cannot extend an approval by writing a far-future time. Approvals are also wiped by V4 whenever the request changes.
- **Binding A** (`-labelled`) uses `objectSelector` on the critical label. Kubernetes evaluates the selector against `object` **or** `oldObject`, so removing the label in the same request still matches (and V2 denies it). **Binding B** (`-named`) covers the name-protected, low-traffic kinds without a selector. Result: the policy costs nothing on the cluster's ordinary Secret/ConfigMap traffic.
- **Fail closed where safe**: `failurePolicy: Fail`; the labelled binding has `parameterNotFoundAction: Deny`, the named binding `Allow`, because the named binding matches every namespace/CRD/cluster-RBAC/group/OLM update cluster-wide and a missing `GuardrailConfig` must not stop OLM or the namespace lifecycle. Its absence is alerted (its deletion is `GuardrailPolicyModified`) and `verify-install.sh` checks it.
- **Type-checking warnings are expected**: `oc get vap guardrails-critical-delete -o yaml` lists warnings such as "undefined field 'spec'" because the policy matches many kinds; evaluation is dynamic. Only a `status.conditions` error or an "expression compile" message is a problem.

## Companion policies

- `guardrails-critical-label-control` – only `gitopsServiceAccounts`, `exemptUsers` or approver-group members may **add** the critical label (CREATE or UPDATE). Without it any tenant with `patch` on a protected kind could mark their own object critical to force the platform team into the workflow or wedge their namespace in Terminating. Bound with the same label `objectSelector`; follows the phase actions.

- `guardrails-gitops-only-mutation` – critical objects may only be *changed* by the Argo CD identities (application-controller, server, applicationset-controller, the GitOps operator), the reaper (annotations only) or break-glass; a human editing the `ArgoCD` CR or the forwarder by hand is flagged (`ArgoCDDirectMutation`) in phases 1–3 and denied in phase 4. The approval workflow is explicitly allowed (only guardrail annotations change).
- `guardrails-rbac-escalation-audit` – never denies; a binding to `cluster-admin`/`admin`/`guardrails-*` or a change to a privileged group "fails" the validation with `[Warn, Audit]`, which stamps the audit event and warns the caller. `PrivilegedRBACChange` alerts on it.

## Self-protection

What stops someone from deleting the policy? Five things, in depth:

1. The bindings, policies, `GuardrailConfig`, `guardrails-*` RBAC and the approver groups are **critical by name** → V1 applies to them (R3 in docs/01: confirm in phase 1 that your build evaluates VAPs against `admissionregistration.k8s.io` objects; the test script includes the case).
2. **RBAC + hardened binding**: approvers may `patch` the policy objects only by name (`resourceNames`), and the `guardrails-gitops-only-mutation-hardened` binding denies, in **every phase**, any change to GuardrailConfig, the policies/bindings, `guardrails-*` RBAC, the privileged Groups, APIServer/OAuth and labelled CronJobs by anyone but the GitOps path, trusted mutators and break-glass. Humans can still add approval annotations to them.
3. **Argo CD self-heal** recreates/reverts them within the sync interval (3 min default); the `guardrails` Application has no cascade finalizer, so deleting the *Application* out of band changes nothing on the cluster (and the Application is itself critical).
4. **Alert** `GuardrailPolicyModified` (P1) on any write to them by anyone but Argo CD.
5. **Git**: the only legitimate path is a PR with two reviewers and code-owner approval (docs/08).

## Flows

Request → approve → execute (CLI):

```bash
scripts/request-deletion.sh argocd openshift-gitops -n openshift-gitops "CHG0012345: migrate to new instance"
# approver 1 and approver 2, each from their own login:
scripts/approve-deletion.sh argocd openshift-gitops -n openshift-gitops
# executor (a third person, in gitops-deletion-requesters):
scripts/execute-deletion.sh argocd openshift-gitops -n openshift-gitops
```

Without the scripts (what they do underneath):

```bash
oc annotate -n openshift-gitops argocd openshift-gitops --overwrite \
  guardrails.example.com/delete-request="CHG0012345: migrate" \
  guardrails.example.com/delete-requested-by="$(oc whoami)" \
  guardrails.example.com/delete-approvals-
# each approver appends only themself:
CUR=$(oc get -n openshift-gitops argocd openshift-gitops -o go-template='{{index .metadata.annotations "guardrails.example.com/delete-approvals"}}')
oc annotate -n openshift-gitops argocd openshift-gitops --overwrite \
  guardrails.example.com/delete-approvals="${CUR:+$CUR,}$(oc whoami)|$(date -u +%Y-%m-%dT%H:%M:%SZ)"
oc delete -n openshift-gitops argocd openshift-gitops
```

Through Git instead of `oc`: if the object is managed from Git, delete it by PR. The Argo CD controller is a `gitopsController` and prunes it without the annotation workflow; `GitOpsCriticalDeletionApplied` fires so the on-call can match it to the merged PR. The annotation workflow is for out-of-band deletions and for objects that are not in Git.

## Adding or removing a critical object

- Label it in Git: `guardrails.example.com/critical: "true"` (kustomize `commonLabels` for a whole component works). Argo CD applies the label; from then on deletion needs approvals.
- Removing the label needs the same approvals as deletion (V2) when done out of band; removing it in Git is applied by the controller (GitOps path).

## Verification

See docs/11, docs/16 (traceability matrix) and `scripts/test-guardrails.sh` (phase-aware). Minimum smoke test after apply:

```bash
oc get vap,vapb -l app.kubernetes.io/part-of=guardrails
oc delete argocd openshift-gitops -n openshift-gitops --dry-run=server   # must be denied with the GUARDRAIL DENIED message
```
