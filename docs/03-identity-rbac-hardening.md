# 03 · Identity and RBAC hardening

## Why

An admission policy decides based on `request.userInfo`. If identities are shared, un-audited or trivially impersonated, the two-person rule degrades to a one-person rule. This document makes every actor a named human from the IdP, removes standing super-user access and makes the remaining super-user paths loud.

## Non-negotiables (do these before phase 3)

1. **Identity provider for everyone.** OAuth to your IdP (OIDC/Entra ID, LDAP, GitHub Enterprise…). Usernames must be stable and personal (`alice@example.com`), because approval entries carry them.
2. **Groups from the IdP.** Either OIDC `groups` claim mapped in the `OAuth` CR, or `oc adm group sync` on a schedule. The five groups in `manifests/00-namespaces-and-groups/groups.yaml` are the contract:

   | Group | Purpose | Cluster RBAC | Argo CD RBAC |
   |---|---|---|---|
   | `platform-admins` | emergency/major changes; **empty at rest**, JIT via PIM | `cluster-admin` (still subject to the guardrail) | `role:admin` |
   | `gitops-deletion-approvers` | approve deletions (≥ 4 people, ≥ 2 teams) | `guardrails-approver` (read + patch, no delete) | `role:readonly` |
   | `gitops-deletion-requesters` | request + execute deletions | `guardrails-approver` + `guardrails-executor` | – |
   | `gitops-operators` | day-2 Argo CD operations | none beyond Argo CD | `role:operator` (no delete) |
   | `auditors` | read-only + logs | `cluster-reader` | project `readonly` |

3. **Remove `kubeadmin`** once an IdP admin login is proven: `oc delete secret kubeadmin -n kube-system`. The `KubeadminOrSystemAdminUsed` alert then catches any reappearance.
4. **Vault the installer kubeconfig** (`auth/kubeconfig`, identity `system:admin`, bypasses OAuth and RBAC audit attribution beyond the CN). Store it under dual control; every use is a P1 alert.
5. **No `User` subjects on `cluster-admin`.** Only the `platform-admins` group and the break-glass SA are bound. `scripts/verify-install.sh` counts violations.
6. **Break-glass is a service account, not a person.** `guardrails-system/breakglass` is bound to `cluster-admin` and listed in `GuardrailConfig.spec.exemptUsers`. Its token is minted on demand by two custodians (`oc create token breakglass -n guardrails-system --duration=1h`), never stored; use raises `BreakGlassUsed`. Procedure in docs/09.
7. **Impersonation is an incident.** `cluster-admin` can `--as=approver1`; there is no admission-side way to distinguish that. `ImpersonationUsed` (any write via impersonation) is P1 to the security channel and the audit event names both identities, so a forged approval is provable after the fact. Keep `impersonate` out of every custom role.

## Why RBAC alone is not enough (and why it is still needed)

RBAC grants verbs on kinds; it cannot say "may patch only these three annotations". So approvers get `patch` on the critical kinds and the **policy** restricts the content of that patch (rule V3/V4 in docs/04: nothing but the guardrail annotations may change in the same request). Conversely the policy does not replace RBAC: it never *grants* anything, it only denies. Both layers must be present.

## Argo CD identities

- Argo CD SSO through OpenShift OAuth (Dex, `spec.sso.dex.openShiftOAuth: true`) so Argo CD usernames equal cluster usernames equal audit usernames.
- Local `admin` account disabled (`spec.disableAdmin: true`).
- Argo CD RBAC (`spec.rbac.policy`) gives `gitops-operators` sync/refresh/rollback but **`delete: deny`** on applications, applicationsets and projects. Deleting through the Argo CD UI/CLI therefore fails at Argo CD level before it ever reaches the admission policy.
- The application-controller SA (`system:serviceaccount:openshift-gitops:openshift-gitops-argocd-application-controller`) is the only identity allowed to *mutate* critical objects (`gitopsServiceAccounts`) but it is **not** exempt from the deletion rule.

## Manifests

`manifests/02-rbac/clusterroles.yaml` (roles + bindings), `manifests/02-rbac/breakglass.yaml`, `manifests/00-namespaces-and-groups/groups.yaml`. All are named `guardrails-*` or are in the privileged-group list, hence critical: changing them needs approvals, and every change is alerted by `PrivilegedRBACChange`.

## OAuth token hygiene

```yaml
# oauth/cluster (excerpt) – shorter tokens, inactivity timeout
spec:
  tokenConfig:
    accessTokenMaxAgeSeconds: 28800          # 8 h
    accessTokenInactivityTimeout: 2h
```

## Verification

```bash
oc get clusterrolebinding -o json | jq -r '.items[] | select(.roleRef.name=="cluster-admin") | "\(.metadata.name): \(.subjects // [] | map("\(.kind)/\(.name)") | join(", "))"'
oc get secret kubeadmin -n kube-system 2>&1 | head -1          # NotFound expected
oc get group gitops-deletion-approvers -o jsonpath='{.users}'  # >= 4 people
oc auth can-i delete argocd -n openshift-gitops --as=approver1@example.com --as-group=gitops-deletion-approvers   # no
oc auth can-i patch  argocd -n openshift-gitops --as=approver1@example.com --as-group=gitops-deletion-approvers   # yes (content limited by policy)
```
