# 17 · Impersonation control: check with `--as`, never change with it

## Why

Kubernetes impersonation (`oc --as=<user> --as-group=<group>`, the `Impersonate-*` headers) is the one path that turns every cluster-side control in this repository into a single-person action: a `cluster-admin` can become an approver and forge an approval, or become the break-glass service account or the Argo CD controller and be exempt. Admission cannot see the impersonation headers; it sees only the resulting identity. The audit log records both identities, so the abuse is provable, but until now it was not *preventable*. Residual risk R1 said as much.

The requirement is precise: **impersonation may be used only for dry-runs, client-side and server-side.** A client-side dry-run (`--dry-run=client`) never sends a write to the API server, so it is inherently unaffected. A server-side dry-run (`--dry-run=server`) goes through admission but is never persisted. Every other write made under an impersonated identity must be denied. Reads and access reviews (`oc auth can-i --as`) remain possible: they change nothing and are the legitimate reason impersonation exists.

## How admission can tell a real session from an impersonated one

The API server does not pass "this request is impersonated" to admission. What it does pass is `request.userInfo.extra`, and a real session carries authentication extras that an impersonated session does not:

| Session type | Extra present on a real session | Present on an impersonated copy? |
|---|---|---|
| Human logged in through OpenShift OAuth (any IdP) | `scopes.authorization.openshift.io` (e.g. `user:full`) | No, unless the impersonator is allowed to impersonate `userextras` |
| Service account using a bound token (every pod's projected token, `oc create token`) | `authentication.kubernetes.io/credential-id` (`JTI=<uuid>`; GA since Kubernetes 1.32, so on every OCP 4.21 cluster) | No, unless the impersonator is allowed to impersonate `userextras` |
| Client-certificate user (`system:admin`) | none | n/a |
| Service account using a legacy secret-based token | none | n/a |

So the design has two halves that only work together:

1. **RBAC: nobody may impersonate `userextras`.** `cluster-admin` (`*` on `*`) can, so humans no longer get `cluster-admin`. They get `guardrails-platform-admin` (every verb on every resource except `impersonate`, `escalate`, `bind`) plus `guardrails-impersonator` (`impersonate` on `users`, `groups`, `serviceaccounts` only). Without `escalate`/`bind` they cannot grant themselves the missing verbs; without `impersonate` on `userextras` they cannot forge the markers. The break-glass service account is bound to `guardrails-platform-admin` as well: it needs no impersonation.
2. **Admission: a write without the marker is impersonated, and impersonated writes are dry-run only.** `guardrails-impersonation-dry-run-only` denies any non-dry-run CREATE/UPDATE/DELETE where a human identity lacks `humanAuthExtraKey` or a privileged service-account identity lacks the bound-token credential-id. In addition, every other guardrail policy now honours exemptions and approver status **only when the marker is present**: an impersonated break-glass is not exempt even in a dry-run, an impersonated approver cannot approve even in a dry-run. Dry-runs therefore show exactly what a real, non-impersonated session would get.

What remains: the group `system:masters` (the installer's `system:admin` certificate) bypasses RBAC entirely and can forge extras. That credential stays in the vault under dual control (docs/03), and any use is alerted (`KubeadminOrSystemAdminUsed`).

## Files

| File | Content |
|---|---|
| `manifests/02-rbac/platform-admin.yaml` | ClusterRoles `guardrails-platform-admin` and `guardrails-impersonator`; binding of the impersonator role to `platform-admins` |
| `manifests/02-rbac/clusterroles.yaml` | `guardrails-platform-admins` now binds `guardrails-platform-admin` instead of `cluster-admin` |
| `manifests/02-rbac/breakglass.yaml` | break-glass bound to `guardrails-platform-admin` |
| `manifests/03-guardrails/vap-impersonation-dry-run-only.yaml` | the policy and its binding (phase-controlled) |
| `manifests/03-guardrails/crd-guardrailconfig.yaml`, `guardrailconfig-default.yaml` | `humanAuthExtraKey` (default `scopes.authorization.openshift.io`), `requireBoundTokenForPrivileged` (default `true`) |
| `vap-critical-delete.yaml`, `vap-critical-label-control.yaml`, `vap-gitops-only-mutation.yaml` | `isExempt`, `isGitOps`, `isReaper`, `isOlmCsvReplacement`, `isTrusted*` require the bound-token marker; `isApprover`, `isRequester` require the human marker |
| `manifests/05-alerting/loki-alertingrules-audit.yaml` | `ImpersonatedWriteDenied` (critical, security) |
| `manifests/overlays/phase1-audit`, `phase2-warn` | the new binding is `[Audit]` / `[Warn, Audit]` like the deletion bindings |

## The policy, line by line

```yaml
matchConstraints: every CREATE/UPDATE/DELETE of every resource in every group
matchConditions:
  not-an-access-review    : groups authorization.k8s.io, authorization.openshift.io, authentication.k8s.io are skipped
                            (oc auth can-i --as creates a SubjectAccessReview; it must keep working)
  not-a-system-component  : identities starting with system: are skipped, except system:serviceaccount:*
variables:
  isServiceAccount  username starts with system:serviceaccount:
  hasBoundToken     'authentication.kubernetes.io/credential-id' in userInfo.extra
  hasHumanMarker    humanAuthExtraKey == '' || humanAuthExtraKey in userInfo.extra
  isPrivilegedSA    isServiceAccount && username in exemptUsers ∪ gitopsControllers ∪ gitopsServiceAccounts ∪ reaperUsers ∪ olmServiceAccounts
  impersonated      (isPrivilegedSA && requireBoundTokenForPrivileged && !hasBoundToken) || (!isServiceAccount && !hasHumanMarker)
  dryRun            has(request.dryRun) && request.dryRun
validation:         dryRun || !impersonated
auditAnnotation:    impersonated-write = "user=… op=… resource=… name=… dryRun=…"  (on every impersonated write, allowed or denied)
```

Why only *privileged* service accounts are checked: a tenant workload might still use a legacy secret-based token (no credential-id). Denying its writes would be an outage with no security benefit, since impersonating an unprivileged SA gains nothing against critical objects. The privileged identities all run as pods with projected bound tokens, or are minted with `oc create token`, so the marker is always present for them.

## Behaviour matrix

| Action under `--as` | Before | Now |
|---|---|---|
| `oc get`, `oc describe` (reads) | allowed | allowed (not admission-reviewed; harmless) |
| `oc auth can-i --as` | allowed, but raised `ImpersonationUsed` | allowed, excluded from the alert |
| `oc create/apply/patch/delete --dry-run=client` | no request sent | no request sent |
| `oc create/apply/patch/delete --dry-run=server` | allowed | allowed; exemptions and approver status are **not** honoured for the impersonated identity, so the result reflects an ordinary user |
| `oc annotate` an approval as an approver | accepted (forged approval) | **denied** by `guardrails-impersonation-dry-run-only`; also V3 denies because `isApprover` is false |
| `oc delete` a critical object as break-glass / Argo CD controller | accepted (bypass) | **denied**: not exempt without the marker, and the write is impersonated |
| Any other write (create a Deployment, patch a ConfigMap) | accepted | **denied** unless dry-run |
| Same actions with `--as-user-extra scopes.authorization.openshift.io=user:full` | n/a | RBAC **forbidden** for every human role (`impersonate` on `userextras` is granted to nobody); only `system:masters` can |

## Corner cases

| Case | Behaviour | What to do |
|---|---|---|
| External OIDC authentication (OCP 4.15+ direct OIDC, hosted control planes) instead of OpenShift OAuth | human sessions may carry no `scopes.authorization.openshift.io` extra → every human write denied | set `humanAuthExtraKey` to an extra your OIDC configuration populates, or `""` to disable the human marker (the SA marker keeps protecting privileged identities and exemptions) |
| Client-certificate human users (custom kubeconfigs, `oc adm create-kubeconfig`) | no extras → writes denied | do not issue certificate identities to humans; use the IdP |
| `kube:admin` (kubeadmin) | OAuth session → has the marker | remove kubeadmin anyway (docs/03) |
| `system:admin` (installer certificate) | skipped by the `system:` condition; can forge extras | vaulted; alerted |
| Legacy secret-based SA token used by a *privileged* identity (e.g. someone created a `kubernetes.io/service-account-token` Secret for the reaper) | treated as impersonated → denied | never create such secrets for the guardrail identities; use projected tokens or `oc create token` |
| CI systems using SA tokens | unprivileged SAs are not checked | none |
| A JIT admin needs to test "what would alice see" | `oc auth can-i --as=alice ...` and `--dry-run=server --as=alice` both work | none |
| `scripts/test-guardrails.sh` in impersonation mode | it forges the markers with `--as-user-extra`, which only a `system:masters` credential may do | run impersonation mode on pre-prod with the installer kubeconfig, or use `IMPERSONATE=false` with real logins (the sign-off mode) |
| Argo CD `argocd-server` acting for a UI user | real bound token → has the marker; it is a trusted mutator, never exempt | none |
| Reaper, OLM, GitOps controllers | pods with projected tokens → marker present | none |
| Someone with `guardrails-platform-admin` creates a ClusterRole granting `impersonate` on `userextras` | RBAC escalation check denies: they do not hold that permission and have no `escalate` verb | `PrivilegedRBACChange` alerts on the attempt |
| Phase 1/2 | the binding is Audit/Warn: impersonated writes succeed and are annotated; `ImpersonatedWriteDenied` does not fire (no 4xx) but the `impersonated-write` audit annotation is present | observe for a week like the other bindings |

## Rollout

The binding follows the deletion bindings' phase schedule (Audit → Warn → Deny). Prerequisite for phase 3: every human on the cluster authenticates through OpenShift OAuth (or `humanAuthExtraKey` is adjusted), and the RBAC change (platform-admins off `cluster-admin`) has been applied and rehearsed: JIT admins must confirm that `oc adm`, `oc debug node`, operator installs and `oc adm must-gather` still work with `guardrails-platform-admin` (they do; the role holds every verb except the three identity-escalation verbs).

## Verification

```bash
# RBAC
oc auth can-i impersonate userextras --as=admin@example.com --as-group=platform-admins      # no
oc auth can-i impersonate users      --as=admin@example.com --as-group=platform-admins      # yes
oc get clusterrolebinding -o json | jq -r '.items[] | select(.roleRef.name=="cluster-admin") | .subjects[]?.name'   # only system:masters
# markers on a real session
oc get --raw /apis/authentication.k8s.io/v1/selfsubjectreviews -X POST -H 'Content-Type: application/json' -d '{"apiVersion":"authentication.k8s.io/v1","kind":"SelfSubjectReview"}' | jq .status.userInfo.extra
# policy (phase 3), as a JIT admin
oc --as=dev@example.com -n guardrails-test create configmap x --from-literal=a=b
→ Error from server (Forbidden): ... 'guardrails-impersonation-dry-run-only' ... GUARDRAIL DENIED: dev@example.com has no authentication marker ... Impersonation may only be used with --dry-run=server or for reads ...
oc --as=dev@example.com -n guardrails-test create configmap x --from-literal=a=b --dry-run=server
→ configmap/x created (server dry run)
oc --as=dev@example.com auth can-i create configmaps -n guardrails-test
→ yes/no (works)
oc --as=system:serviceaccount:guardrails-system:breakglass -n openshift-gitops delete argocd openshift-gitops --dry-run=server
→ Error from server (Forbidden): ... 'guardrails-critical-delete' ... (not exempt without a bound token)
```
Automated: `scripts/test-guardrails.sh` §10. Manual: `docs/14` T17. Alert: `ImpersonatedWriteDenied` in Teams (security).

## Respond

`ImpersonatedWriteDenied` or `PrivilegedIdentityImpersonated`: the audit event names both identities (`user`, `impersonatedUser`). Treat a non-dry-run attempt as a bypass attempt: revoke the actor's OAuth tokens (`oc delete oauthaccesstokens --field-selector=userName=<user>`), remove JIT membership at the IdP, open an incident. A dry-run under impersonation is normal testing and is not alerted.
