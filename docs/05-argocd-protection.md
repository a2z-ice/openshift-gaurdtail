# 05 · Argo CD (OpenShift GitOps) protection

## Why

Argo CD is both the most valuable object on the cluster and the tool that can delete the most objects the fastest. Three distinct deletion paths exist and each needs its own control:

| Path | Example | Control |
|---|---|---|
| Delete Argo CD itself | `oc delete argocd`, `oc delete ns openshift-gitops`, uninstall the operator, delete the `argoproj.io` CRDs | Admission guardrail (name-protected), alerts, backups |
| Delete *through* Argo CD | delete an `Application` that has `resources-finalizer.argocd.argoproj.io` → Argo CD deletes every managed resource; delete an `ApplicationSet` → its Applications (and their resources) go | No cascade finalizers, `preserveResourcesOnDeletion`, Argo CD RBAC `delete: deny`, Applications labelled critical |
| Delete *via Git* | remove a manifest → auto-sync with `prune: true` deletes it | **the approved path**: the repository ruleset (2 reviewers, code owners, CI invariants) is the control; the controller is a `gitopsController`; `GitOpsCriticalDeletionApplied` alerts for PR correlation |

## ArgoCD CR hardening (`manifests/04-argocd/argocd-cr-hardening-patch.yaml`)

| Field | Value | Why |
|---|---|---|
| `metadata.labels[guardrails.example.com/critical]` | `"true"` | deletion needs approvals (also name-protected) |
| `spec.disableAdmin` | `true` | no shared local password |
| `spec.sso.dex.openShiftOAuth` | `true` | Argo CD identity = cluster identity = audit identity |
| `spec.rbac.defaultPolicy` | `role:readonly` | everyone can look, nobody can act by default |
| `spec.rbac.policy` | `role:operator` with `applications, delete, deny`, `projects, delete, deny`, `exec, create, deny` | day-2 operators cannot delete apps or exec into pods via Argo CD |
| `spec.controller.env ARGOCD_CONTROLLER_DIFF_SERVER_SIDE` | `"true"` | server-side diff, so human-added approval annotations are not seen as drift (an `extraConfig` key would be a no-op) |
| `spec.rbac.policy` (cont.) | `applications, override, deny`; `create/update, guardrails/*, deny`; `applicationsets, create/update, deny` | operators cannot `sync --local` arbitrary manifests as the controller, nor point an Application in the guardrails project at another branch |
| `spec.extraConfig.resource.customizations.ignoreDifferences.all` | the three `delete-*` annotations | belt and braces for the above |
| `spec.server.route.tls.termination` | `reencrypt` | TLS end to end |

Apply it as a server-side apply with its own field manager (Argo CD does that when it is in the `guardrails` Application), so the operator-managed fields and the Git-managed fields coexist.

## Applications and ApplicationSets

Rules for every production `Application`:

1. **No `resources-finalizer.argocd.argoproj.io`** unless you explicitly want "delete app ⇒ delete workloads". For existing apps: `oc -n openshift-gitops patch application <app> --type json -p '[{"op":"remove","path":"/metadata/finalizers"}]'`.
2. `syncPolicy.automated.prune: true` is correct for Git-managed applications whose repository enforces the 2-reviewer ruleset (Git is the source of truth); keep `prune: false` only where the repository does not.
3. `syncPolicy.automated.selfHeal: true` so out-of-band edits are reverted (this is what makes the guardrail objects self-protecting).
4. Label `guardrails.example.com/critical: "true"` on the Application itself so deleting the *Application* needs approvals.
5. For `ApplicationSet`s: `spec.syncPolicy.preserveResourcesOnDeletion: true` (affects newly generated Applications only) and `applicationsSync: sync` so a template change cannot re-enable prune per app. Template in `applicationset-defaults-snippet.yaml`.

The `guardrails` Application (`application-guardrails.yaml`) follows all five, points at the overlay of the current phase, prunes, and has `ignoreDifferences` for the three approval annotations plus `Group.users` (owned by IdP sync).

## AppProject fencing (`appproject-guardrails.yaml`)

`sourceRepos` pinned to this repository, `destinations` listing **every** namespace the base renders into (openshift-gitops, openshift-gitops-operator, guardrails-system, openshift-logging, openshift-operators-redhat, openshift-monitoring, openshift-adp, openshift-etcd-backup, openshift-kube-apiserver; a missing one makes the sync fail), `clusterResourceWhitelist` limited to the kinds this repository actually manages. A compromised app repo therefore cannot deploy a `ValidatingAdmissionPolicyBinding` that neutralises the guardrail.

## What happens when Git deletes a critical manifest

1. A PR removes a manifest. CI invariants reject known weakenings (a binding losing `Deny`, humans in exempt lists); otherwise two reviewers including a code owner from security must approve.
2. After merge, Argo CD prunes the object as `openshift-gitops-argocd-application-controller`, a `gitopsController`: the deletion is allowed.
3. `GitOpsCriticalDeletionApplied` (warning) reaches Teams with the object and identity; the on-call links it to the PR (`git log -S <name>`). A Git-driven deletion **without** a matching PR means the controller identity is compromised: treat as `CriticalResourceDeleted` and check `PrivilegedTokenMinted`.
4. Deleting the same object through the Argo CD **UI** is not the Git path: `argocd-server` is denied unless the workflow ran (and Argo CD RBAC already denies delete to operators).

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
