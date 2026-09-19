# 09 · Runbooks

All commands assume `oc` is logged in with a personal IdP identity. Never use `kubeadmin`, `system:admin` or the break-glass token for routine work; each of those raises a P1.

## Request, approve and execute a deletion

**Is the object managed from Git?** Then delete it with a PR (two reviewers); Argo CD prunes it and `GitOpsCriticalDeletionApplied` confirms. The workflow below is for **out-of-band** deletions (objects not in Git, emergencies). **Tier-B kinds** (namespaces, CRDs, OLM objects, Secrets, ServiceAccounts) cannot be deleted by the workflow roles; use Git, or break-glass.

Roles: **requester** (`gitops-deletion-requesters` or an approver), **two approvers** (`gitops-deletion-approvers`, not the requester), **executor** (`gitops-deletion-requesters`, not an approver). Change ticket first.

1. Requester:
   ```bash
   scripts/request-deletion.sh <resource> <name> [-n <ns>] "CHG0012345: <reason>"
   ```
   Post the change ticket and the object in the Teams channel; the `CriticalDeletionApprovalRecorded` info alert appears there too.
2. Approver 1, then approver 2, each from their own session:
   ```bash
   scripts/approve-deletion.sh <resource> <name> [-n <ns>]
   ```
   The script shows the request and asks for the literal word `approve`. It fails if you are the requester, already approved, or not in the group.
3. Executor, within `approvalTTL` (4 h):
   ```bash
   scripts/execute-deletion.sh <resource> <name> [-n <ns>]
   ```
   The red `CriticalResourceDeleted` alert to email + Teams is **expected**; acknowledge it in the channel with the change ticket.
4. If the object is managed by Argo CD, merge the PR that removes it from Git in the same change window, otherwise self-heal recreates it.

Cancel at any time: `scripts/cancel-deletion.sh <resource> <name> [-n <ns>]`.

### Deletion denied

Message `GUARDRAIL DENIED: …` tells you what is missing. Check state: `scripts/request-deletion.sh` output or

```bash
oc get <resource> <name> -n <ns> -o jsonpath='{.metadata.annotations}' | tr ',' '\n' | grep guardrails
```

Common causes: only one approval; approver was also the requester; executor is one of the approvers (`executorMayBeApprover=false`); approvals expired or future-dated (reaper removed them: re-approve); an attempt to change the request text without clearing approvals (denied by V4: use `request-deletion.sh` again); approver not in `gitops-deletion-approvers` (IdP sync lag: `oc get group gitops-deletion-approvers`); a Tier-B kind (RBAC Forbidden: Git or break-glass).

## Respond to a red alert

`CriticalResourceDeleted`, `GitOpsResourceDeleted`, `GitOpsNamespaceTerminating`, `ArgoCD*Missing`:

1. **Acknowledge** in Teams within 5 min (on-call). Open an incident if there is no change ticket referenced in the last `CriticalDeletionApprovalRecorded` message for that object.
2. **Attribute**: `scripts/audit-query.sh <name>` (or the LogQL/SPL it prints). Confirm actor, `impersonatedUser`, approvers list in `annotations_guardrails_critical_delete_decision`, source IP, user agent.
3. **Classify**:
   - approved via the workflow with a valid ticket → expected; close.
   - `gitops=true` (`GitOpsCriticalDeletionApplied`) with a merged PR that removed the object → expected GitOps path; link the PR. **No PR** → the controller identity is compromised: treat as `CriticalResourceDeleted`, check `PrivilegedTokenMinted` and `ControlPlaneNodeAccess`, rotate by restarting the controller pods (bound tokens expire) and page security.
   - exempt identity (`exempt=true`): break-glass or `system:apiserver` → must map to an open break-glass incident; otherwise treat as compromise.
   - impersonation present → security incident (forged approval).
   - no `decision` annotation at all on a delete of a GitOps object → the policy did not evaluate: check `GuardrailPolicyModified` history immediately.
4. **Contain**: if compromise is suspected, revoke the actor's OAuth tokens as an admin (`oc delete oauthaccesstokens --field-selector=userName=<user>`; `useroauthaccesstokens` only lists your own), remove them from groups at the IdP. A minted break-glass or SA token **cannot be revoked** (bound tokens): it expires (1 h for break-glass); until then watch `BreakGlassUsed`/`ArgoCDDirectMutation` and, for an Argo CD SA token, restart the controller pods so the projected token rotates and remove the actor's ability to mint again.
5. **Recover**: "Restore Argo CD" below, or re-sync the affected Application from Git.
6. **Post-mortem** within 5 working days: timeline from the audit log, which layer failed or worked, actions.

### Guardrail tampering (`GuardrailPolicyModified`, `AuditProfileChanged`, `AuditForwarderChanged`, `PrivilegedRBACChange`)

1. `oc get application guardrails -n openshift-gitops -o jsonpath='{.status.sync.status} {.status.health.status}'` – if `OutOfSync`, Argo CD will heal within 3 min; force it: `argocd app sync guardrails` (or the UI).
2. Diff live vs Git: `argocd app diff guardrails`.
3. Attribute with `scripts/audit-query.sh <object>`; a write by anyone but the Argo CD SA is a security incident unless it is a documented break-glass.
4. Verify the control is back: `oc delete argocd openshift-gitops -n openshift-gitops --dry-run=server` must be denied.

### Detection pipeline (`AuditLogIngestionStalled`, `LokiRulerDown`, `AuditForwarderNotReady`)

```bash
oc get clusterlogforwarder audit-forwarder -n openshift-logging -o yaml | yq '.status.conditions'
oc get pods -n openshift-logging -l app.kubernetes.io/component=collector -o wide
oc logs -n openshift-logging ds/audit-forwarder --tail=100 | grep -iE 'error|warn'
oc get lokistack logging-loki -n openshift-logging -o yaml | yq '.status'
oc get pods -n openshift-logging -l app.kubernetes.io/component=ruler
```
While the pipeline is down, the metrics alerts still cover Argo CD availability; raise the incident priority and monitor the SIEM directly.

## Break-glass

Use when approvers are unreachable (IdP outage, disaster), or when a **Tier-B** object (namespace, CRD, OLM object, Secret, ServiceAccount) must be deleted out of band. Two custodians (`breakglass-custodians` group), one incident ticket, one hour.

1. Custodian A opens the incident and posts in the security channel: object, reason, custodians' names.
2. Custodian A (a member of `breakglass-custodians`, the only role with `create` on `serviceaccounts/token` for this SA) mints the token with custodian B watching; `PrivilegedTokenMinted` fires and must match the incident:
   ```bash
   oc create token breakglass -n guardrails-system --duration=1h > /dev/shm/bg.token
   ```
3. Perform the minimal action with `oc --token=$(cat /dev/shm/bg.token) …`. Every request raises `BreakGlassUsed`; that is the audit trail.
4. Shred the token file; the token expires in 1 h regardless. Post the exact commands in the incident.
5. Post-mortem: why were approvers unreachable; fix that.

If the *repository* needs an emergency merge, an org admin temporarily adds themselves as a bypass actor on the ruleset (GitHub audit log records it), merges with a second person reviewing live, and removes the bypass before closing the incident.

## Restore Argo CD

Symptoms: `ArgoCDApplicationControllerMissing`, `ArgoCDServerMissing`, `GitOpsNamespaceTerminating`, `CriticalResourceDeleted` for `argocds`.

1. Incident + attribution (above).
2. Assess what is left:
   ```bash
   oc get ns openshift-gitops openshift-gitops-operator
   oc get csv -n openshift-gitops-operator
   oc get argocd -n openshift-gitops
   oc get application,appproject -n openshift-gitops
   oc get crd | grep argoproj
   ```
3. Operator gone → reinstall from the cluster-config repo (Subscription in `openshift-gitops-operator`); wait `oc get csv -n openshift-gitops-operator -w` → Succeeded; the operator recreates the default `ArgoCD/openshift-gitops`.
4. Instance/applications gone → `oc apply --server-side -k manifests/overlays/<current-phase>`; this restores the hardening patch, the `guardrails` AppProject/Application; then bootstrap your other app-of-apps from their repos.
5. Credentials → `velero restore create argocd-secrets-$(date +%s) --from-backup <latest gitops-6h> --include-namespaces openshift-gitops --include-resources secrets` (or ESO re-sync).
6. Verify: `scripts/verify-install.sh`; `argocd app list` shows all apps Synced/Healthy; `oc delete argocd openshift-gitops -n openshift-gitops --dry-run=server` denied.
7. Expected RTO: 10 min (instance only) – 30 min (operator + instance).

## Impersonated write denied

`ImpersonatedWriteDenied`: someone ran a write with `--as` and without `--dry-run=server`. The audit event names the real user (`user.username`) and the assumed identity (`impersonatedUser.username`). Legitimate testing uses dry-run; a real write attempt is a bypass attempt: revoke the actor's tokens (`oc delete oauthaccesstokens --field-selector=userName=<user>`), remove JIT membership at the IdP, open an incident. Details: docs/17.

## Git-driven deletion

`GitOpsCriticalDeletionApplied` fired. Find the PR: `git log --oneline -S '<object name>' -- manifests/` (or the application repository). If a merged PR removed the object: expected, link it in the alert thread. If not: incident (see Respond to a red alert, classification `gitops=true` without PR).

## Reaper

`GuardrailReaperFailing`: `oc logs -n guardrails-system job/<name>`; typical causes: image pull (disconnected mirror), RBAC drift (self-heal fixes), a denied patch (policy V3 change). Approvals older than the TTL simply remain until fixed; nothing becomes *less* safe.

Change the TTL: PR on `guardrailconfig-default.yaml` (`approvalTTL`).

## Onboarding / offboarding an approver

IdP group change (JML process) → group sync → `PrivilegedRBACChange` alert confirms → the approver runs `scripts/approve-deletion.sh` on the quarterly test object (docs/12) as proof. Keep ≥ 4 approvers across ≥ 2 teams.

## Post-mortem template

- Summary, impact, detection time (alert timestamp − audit `requestReceivedTimestamp`), response time.
- Timeline from `scripts/audit-query.sh` output (paste the lines).
- Which layers held / failed (L1–L8 from docs/01).
- Residual-risk register updates (docs/01), actions with owners and dates.
