# 05 · Argo CD (OpenShift GitOps) protection

## Why

Argo CD is both the most valuable object on the cluster and the tool that can delete the most objects the fastest. Three distinct deletion paths exist and each needs its own control:

| Path | Example | Control |
|---|---|---|
| Delete Argo CD itself | `oc delete argocd`, `oc delete ns openshift-gitops`, uninstall the operator, delete the `argoproj.io` CRDs | Admission guardrail (name-protected), alerts, backups |
| Delete *through* Argo CD | delete an `Application` that has `resources-finalizer.argocd.argoproj.io` → Argo CD deletes every managed resource; delete an `ApplicationSet` → its Applications (and their resources) go | No cascade finalizers, `preserveResourcesOnDeletion`, Argo CD RBAC `delete: deny`, Applications labelled critical |
| Delete *via Git* | remove a manifest → auto-sync with `prune: true` deletes it | `prune: false` for critical apps; the controller SA is not exempt so a prune of a critical object is denied and alerted; 2-reviewer PRs |

## ArgoCD CR hardening (`manifests/04-argocd/argocd-cr-hardening-patch.yaml`)

| Field | Value | Why |
|---|---|---|
| `metadata.labels[guardrails.example.com/critical]` | `"true"` | deletion needs approvals (also name-protected) |
| `spec.disableAdmin` | `true` | no shared local password |
| `spec.sso.dex.openShiftOAuth` | `true` | Argo CD identity = cluster identity = audit identity |
| `spec.rbac.defaultPolicy` | `role:readonly` | everyone can look, nobody can act by default |
| `spec.rbac.policy` | `role:operator` with `applications, delete, deny`, `projects, delete, deny`, `exec, create, deny` | day-2 operators cannot delete apps or exec into pods via Argo CD |
| `spec.resourceExclusions` | `guardrails.example.com/*` | no unrelated Application can adopt (and later prune) guardrail objects |
| `spec.extraConfig.controller.diff.server.side` | `"true"` | server-side diff, so human-added approval annotations are not seen as drift |
| `spec.extraConfig.resource.customizations.ignoreDifferences.all` | the three `delete-*` annotations | belt and braces for the above |
| `spec.server.route.tls.termination` | `reencrypt` | TLS end to end |

Apply it as a server-side apply with its own field manager (Argo CD does that when it is in the `guardrails` Application), so the operator-managed fields and the Git-managed fields coexist.

## Applications and ApplicationSets

Rules for every production `Application`:

1. **No `resources-finalizer.argocd.argoproj.io`** unless you explicitly want "delete app ⇒ delete workloads". For existing apps: `oc -n openshift-gitops patch application <app> --type json -p '[{"op":"remove","path":"/metadata/finalizers"}]'`.
2. `syncPolicy.automated.prune: false` and `syncOptions: [Prune=false]` for anything critical; use a manual, reviewed sync with prune for intentional removals.
3. `syncPolicy.automated.selfHeal: true` so out-of-band edits are reverted (this is what makes the guardrail objects self-protecting).
4. Label `guardrails.example.com/critical: "true"` on the Application itself so deleting the *Application* needs approvals.
5. For `ApplicationSet`s: `spec.syncPolicy.preserveResourcesOnDeletion: true` (affects newly generated Applications only) and `applicationsSync: sync` so a template change cannot re-enable prune per app. Template in `applicationset-defaults-snippet.yaml`.

The `guardrails` Application (`application-guardrails.yaml`) follows all five, points at the overlay of the current phase, and has `ignoreDifferences` for the three approval annotations plus `Group.users` (owned by IdP sync).

## AppProject fencing (`appproject-guardrails.yaml`)

`sourceRepos` pinned to this repository, `destinations` limited to the platform namespaces, `clusterResourceWhitelist` limited to the kinds this repository actually manages. A compromised app repo therefore cannot deploy a `ValidatingAdmissionPolicyBinding` that neutralises the guardrail.

## What happens when Git deletes a critical manifest

1. PR removes `manifests/03-guardrails/vap-critical-delete-bindings.yaml` and gets merged (two reviewers were fooled or colluded).
2. Argo CD marks the live binding as *orphaned/OutOfSync*; with `prune: false` it does **not** delete it. Nothing changes on the cluster.
3. If someone runs a manual sync with prune, the controller SA issues DELETE → V1 denies (the SA is not exempt, no approvals) → sync fails with the GUARDRAIL message → `CriticalResourceDeleteDenied` alert to Teams/email.
4. The binding stays; the PR is reverted.

## Operator and CRDs

- The OpenShift GitOps `Subscription`, `ClusterServiceVersion` and `OperatorGroup` in `openshift-gitops-operator` are name-protected: uninstalling the operator needs approvals. (OLM v0 leaves CRDs and CRs in place when a CSV is removed; the Argo CD workloads would stop being reconciled but not deleted.)
- The `argoproj.io`, `guardrails.example.com`, `loki.grafana.com`, `observability.openshift.io`, `velero.io` and `oadp.openshift.io` CRDs are protected by group: deleting a CRD deletes every instance cluster-wide, which is the single most destructive command available.
- If you moved to OLM v1 (`ClusterExtension`), objects whose name contains `gitops` are protected too.

## Repository and cluster credentials

Argo CD repo/cluster `Secret`s carry `argocd.argoproj.io/secret-type`; label them `guardrails.example.com/critical=true` (kustomize `commonLabels` in the component that creates them, or ESO `template.metadata.labels`). Losing a cluster secret silently detaches a spoke cluster.

## Verification

```bash
oc get argocd openshift-gitops -n openshift-gitops -o jsonpath='{.spec.disableAdmin}{" "}{.spec.rbac.defaultPolicy}{"\n"}'
oc get application -n openshift-gitops -o custom-columns=NAME:.metadata.name,FINALIZERS:.metadata.finalizers,PRUNE:.spec.syncPolicy.automated.prune,CRITICAL:.metadata.labels.guardrails\.example\.com/critical
oc get applicationset -n openshift-gitops -o custom-columns=NAME:.metadata.name,PRESERVE:.spec.syncPolicy.preserveResourcesOnDeletion
argocd account can-i delete applications '*/*' --as gitops-operators   # no
```
