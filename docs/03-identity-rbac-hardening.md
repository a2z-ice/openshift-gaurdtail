# 03 · Identity and RBAC hardening

## Why

An admission policy decides based on `request.userInfo`. If identities are shared, un-audited or trivially impersonated, the two-person rule degrades to a one-person rule. This document makes every actor a named human from the IdP, removes standing super-user access and makes the remaining super-user paths loud.

## Non-negotiables (do these before phase 3)

1. **Identity provider for everyone.** OAuth to your IdP (OIDC/Entra ID, LDAP, GitHub Enterprise…). Usernames must be stable and personal (`alice@example.com`), because approval entries carry them.
2. **Groups from the IdP.** Either OIDC `groups` claim mapped in the `OAuth` CR, or `oc adm group sync` on a schedule. The five groups in `manifests/00-namespaces-and-groups/groups.yaml` are the contract:

   | Group | Purpose | Cluster RBAC | Argo CD RBAC |
   |---|---|---|---|
   | `platform-admins` | emergency/major changes; **empty at rest**, JIT via PIM | `guardrails-platform-admin` (all verbs except impersonate/escalate/bind) + `guardrails-impersonator` | `role:admin` |
   | `gitops-deletion-approvers` | approve deletions (≥ 4 people, ≥ 2 teams) | `guardrails-approver` (read + patch, no delete) | `role:readonly` |
   | `gitops-deletion-requesters` | request + execute deletions | `guardrails-approver` + `guardrails-executor` | – |
   | `gitops-operators` | day-2 Argo CD operations | none beyond Argo CD | `role:operator` (no delete) |
   | `auditors` | read-only + logs | `cluster-reader` | project `readonly` |

3. **Remove `kubeadmin`** once an IdP admin login is proven: `oc delete secret kubeadmin -n kube-system`. The `KubeadminOrSystemAdminUsed` alert then catches any reappearance.
4. **Vault the installer kubeconfig** (`auth/kubeconfig`, identity `system:admin`, bypasses OAuth and RBAC audit attribution beyond the CN). Store it under dual control; every use is a P1 alert.
5. **Nothing but `system:masters` on `cluster-admin`.** Neither users nor groups nor the break-glass SA are bound to `cluster-admin` any more; `scripts/verify-install.sh` checks both and also that no custom ClusterRole grants `impersonate` on `userextras`.
6. **Break-glass is a service account, not a person.** `guardrails-system/breakglass` is bound to `cluster-admin` and listed in `GuardrailConfig.spec.exemptUsers`. Only the `breakglass-custodians` group (Role `guardrails-breakglass-custodian`, `create` on `serviceaccounts/token` for that one SA) and JIT cluster-admins can mint its token (`oc create token breakglass -n guardrails-system --duration=1h`); minting raises `PrivilegedTokenMinted`, every use raises `BreakGlassUsed`. Bound tokens cannot be revoked, so the duration is short and the mint is the audited event. Procedure in docs/09.
7. **Impersonation is for checking, never for changing.** Humans and break-glass are bound to `guardrails-platform-admin` (every verb except `impersonate`, `escalate`, `bind`), never to `cluster-admin`; JIT admins additionally get `guardrails-impersonator` (`impersonate` on users, groups, serviceaccounts, never `userextras`). Because a real session carries authentication markers in `userInfo.extra` that an impersonator cannot forge, admission honours exemptions and approver status only with the marker and denies any non-dry-run write under impersonation (`guardrails-impersonation-dry-run-only`). `oc auth can-i --as` and `--dry-run=server --as` keep working. Full design and corner cases: docs/17.

## Why RBAC alone is not enough (and why it is still needed)

RBAC grants verbs on kinds; it cannot say "may patch only these three annotations" and it cannot select objects by label. Two consequences shape `manifests/02-rbac/clusterroles.yaml`:

1. **Scope with what RBAC has**: `resourceNames` for cluster-scoped objects with known names, and namespaced RoleBindings (`rolebindings.yaml`) in the platform namespaces for kinds that cannot be enumerated. Approvers therefore have **no** cluster-wide `patch` or `get` on Secrets, ConfigMaps or Namespaces.
2. **Two tiers**: *Tier A* kinds are in the workflow (Argo CD CRs, GuardrailConfig, the policies, `guardrails-*` RBAC, the groups, APIServer/OAuth, logging/alerting/backup CRs, the named CronJobs/ConfigMaps). *Tier B* kinds (Namespaces, CRDs, OLM Subscription/CSV/OperatorGroup, Secrets, ServiceAccounts) are never patchable or deletable by a human role, because a spec patch on them is a privilege-escalation primitive (secret contents, conversion webhooks, operator pod specs, PSA labels). They change through Git, or through break-glass.

The **policy** then restricts the content of any patch an approver can make (V3/V4: nothing but the guardrail annotations may change in the same request; the `-hardened` GitOps-only binding denies any other change to the self-protection set in every phase). Conversely the policy does not replace RBAC: it never *grants* anything. Both layers must be present.

## Argo CD identities

- Argo CD SSO through OpenShift OAuth (Dex, `spec.sso.dex.openShiftOAuth: true`) so Argo CD usernames equal cluster usernames equal audit usernames.
- Local `admin` account disabled (`spec.disableAdmin: true`).
- Argo CD RBAC (`spec.rbac.policy`) gives `gitops-operators` sync/refresh/rollback but **`delete: deny`** on applications, applicationsets and projects. Deleting through the Argo CD UI/CLI therefore fails at Argo CD level before it ever reaches the admission policy.
- The application-controller and ApplicationSet-controller SAs are the **GitOps path** (`gitopsControllers`): what they apply was merged through the 2-reviewer ruleset, so they are exempt from the cluster-side workflow. `argocd-server` (UI/CLI actions) and the GitOps operator are trusted *mutators* only (`gitopsServiceAccounts`): they may update critical objects but not delete them without the workflow.

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
oc auth can-i get secrets -n openshift-gitops --as=approver1@example.com --as-group=gitops-deletion-approvers        # no (Tier B)
oc auth can-i delete namespaces --as=req@example.com --as-group=gitops-deletion-requesters                          # no (Tier B)
```
