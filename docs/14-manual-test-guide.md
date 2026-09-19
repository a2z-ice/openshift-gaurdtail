# 14 · Manual test guide

A step-by-step guide any operator can follow to prove every control, positive and negative, with the exact commands and the output to expect. Run it in full on pre-prod before phase 3, and the marked subset (★) on production after each phase change and after every OpenShift, Logging or GitOps upgrade. Record results in the table in §17 and attach the evidence to the change ticket.

Conventions: `$` = run as the identity named in the step. Expected output is shown after `→`. Where output contains timestamps, names or UIDs, only the shape matters. `PFX` is the annotation prefix (`guardrails.example.com` until you replaced it).

## 0. Prerequisites and test identities

You need four personal IdP accounts (never shared accounts):

| Role | Example user | Group membership |
|---|---|---|
| Requester / executor | `req@example.com` | `gitops-deletion-requesters` |
| Approver 1 | `a1@example.com` | `gitops-deletion-approvers` |
| Approver 2 | `a2@example.com` | `gitops-deletion-approvers` |
| Admin (has cluster-admin, e.g. JIT `platform-admins`) | `admin@example.com` | `platform-admins` |

Log each one in once and save a kubeconfig per identity:

```bash
$ oc login --server=https://api.<cluster>:6443 -u req@example.com    # repeat for a1, a2, admin
$ oc config view --minify --flatten > ~/.kube/req.kubeconfig          # and a1 / a2 / admin
```

Helpers used throughout:

```bash
export PFX=guardrails.example.com
export NS=guardrails-test
alias as-req='KUBECONFIG=~/.kube/req.kubeconfig oc'
alias as-a1='KUBECONFIG=~/.kube/a1.kubeconfig oc'
alias as-a2='KUBECONFIG=~/.kube/a2.kubeconfig oc'
alias as-admin='KUBECONFIG=~/.kube/admin.kubeconfig oc'
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
state() { oc -n $NS get cm "$1" -o go-template='{{range $k,$v := .metadata.annotations}}{{if hasPrefix $k "guardrails."}}{{$k}}={{$v}}{{"\n"}}{{end}}{{end}}'; }
```

Confirm the platform state before testing:

```bash
$ as-admin get guardrailconfig default -o jsonpath='{.spec.minApprovers} {.spec.executorMayBeApprover}{"\n"}'
→ 2 false
$ as-admin get vapb -l app.kubernetes.io/part-of=guardrails -o custom-columns=NAME:.metadata.name,ACTIONS:.spec.validationActions
→ guardrails-critical-delete-labelled   [Deny Audit]      (phase 3/4; [Audit] in phase 1; [Warn Audit] in phase 2)
  guardrails-critical-delete-named      [Deny Audit]
  guardrails-gitops-only-mutation       [Audit]           ([Deny Audit] in phase 4)
  guardrails-rbac-escalation-audit      [Warn Audit]
$ as-admin get vap guardrails-critical-delete -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}{"\n"}'
→ True
$ as-admin get group gitops-deletion-approvers -o jsonpath='{.users}{"\n"}'
→ ["a1@example.com","a2@example.com", ...]
```

Create the scratch objects (the namespace is not critical; the ConfigMap is):

```bash
$ as-admin create ns $NS
$ as-admin -n $NS create configmap victim --from-literal=a=b
$ as-admin -n $NS label configmap victim $PFX/critical=true
$ as-admin -n $NS create configmap bystander --from-literal=a=b
$ as-admin -n $NS get cm --show-labels
→ NAME        DATA   AGE   LABELS
  bystander   1      5s    <none>
  victim      1      9s    guardrails.example.com/critical=true
```

Open a second terminal that tails the audit stream so you can see every decision live (optional but recommended):

```bash
$ logcli query --org-id=audit --tail '{log_type="audit"} | json | objectRef_namespace="guardrails-test" | line_format "{{.verb}} {{.objectRef_name}} by {{.user_username}} rc={{.responseStatus_code}} :: {{.annotations_guardrails_critical_delete_decision}} :: {{.annotations_validation_policy_admission_k8s_io_validation_failure}}"'
```

## 1. Phase-1 behaviour (audit only) — run once during phase 1

**T1.1 – a would-be-denied delete succeeds but is annotated.**

```bash
$ as-admin -n $NS delete configmap victim --dry-run=server
→ configmap "victim" deleted (server dry run)
```
In the audit tail:
```
→ delete victim by admin@example.com rc=200 :: op=DELETE user=admin@example.com ... approved=false exempt=false :: [{"message":"GUARDRAIL DENIED: ...","policy":"guardrails-critical-delete","binding":"guardrails-critical-delete-named","expressionIndex":0,"validationActions":["Audit"]}]
```
Pass = `rc=200` **and** the `validation_failure` annotation is present. This is the evidence phase 1 collects.

## 2. Baseline: non-critical objects are untouched ★

**T2.1**
```bash
$ as-admin -n $NS delete configmap bystander
→ configmap "bystander" deleted
```
Audit tail: `delete bystander by admin@example.com rc=200 :: :: ` (both annotations empty; the policy did not consider it critical).

**T2.2 – ordinary updates to critical objects that do not touch guardrail annotations are allowed for the GitOps identity and flagged (not blocked) for humans in phases 1–3.**
```bash
$ as-admin -n $NS annotate configmap victim team=platform --overwrite
→ configmap/victim annotated
```
(Phase 4: `→ Error from server (Forbidden): ... guardrails-gitops-only-mutation ... may only be changed through Git (Argo CD)`.) Audit tail shows `annotations_guardrails_gitops_only_mutation_direct_mutation` populated; Teams receives `ArgoCDDirectMutation` (warning) within ~1 min.

## 3. No single identity can delete a critical object ★

Each command must be **denied** with `Error from server (Forbidden)` and a `GUARDRAIL DENIED` message naming the policy and binding.

**T3.1 – cluster-admin deletes the labelled ConfigMap.**
```bash
$ as-admin -n $NS delete configmap victim
→ Error from server (Forbidden): configmaps "victim" is forbidden: ValidatingAdmissionPolicy 'guardrails-critical-delete' with binding 'guardrails-critical-delete-labelled' denied request: GUARDRAIL DENIED: deleting critical configmaps guardrails-test/victim requires a delete-request and at least 2 distinct approvals from gitops-deletion-approvers (found 0, requested-by=, executor may not be an approver). Runbook: https://.../docs/09-runbooks.md
```
Teams/email: `CriticalResourceDeleteDenied` (warning) with actor and object within ~1 min.

**T3.2 – cluster-admin removes the critical label ("unlabel then delete").**
```bash
$ as-admin -n $NS label configmap victim $PFX/critical-
→ Error from server (Forbidden): ... denied request: GUARDRAIL DENIED: removing the guardrails.example.com/critical label requires the same approvals as a deletion.
```

**T3.3 – delete by label selector / delete collection.**
```bash
$ as-admin -n $NS delete configmap -l $PFX/critical=true
→ Error from server (Forbidden): ... GUARDRAIL DENIED: deleting critical configmaps guardrails-test/victim ...
```

**T3.4 – the Argo CD instance (server dry-run still goes through admission; nothing is deleted).**
```bash
$ as-admin -n openshift-gitops delete argocd openshift-gitops --dry-run=server
→ Error from server (Forbidden): argocds.argoproj.io "openshift-gitops" is forbidden: ValidatingAdmissionPolicy 'guardrails-critical-delete' with binding 'guardrails-critical-delete-named' denied request: GUARDRAIL DENIED: deleting critical argocds openshift-gitops/openshift-gitops requires ...
```

**T3.5 – the GitOps namespace.**
```bash
$ as-admin delete namespace openshift-gitops --dry-run=server
→ Error from server (Forbidden): namespaces "openshift-gitops" is forbidden: ... GUARDRAIL DENIED: deleting critical namespaces openshift-gitops requires ...
$ as-admin delete project openshift-gitops --dry-run=server
→ Error from server (Forbidden): ... (same policy; the project API deletes the namespace through kube-apiserver)
```

**T3.6 – the Argo CD CRDs and the operator.**
```bash
$ as-admin delete crd applications.argoproj.io --dry-run=server
→ Error from server (Forbidden): customresourcedefinitions.apiextensions.k8s.io "applications.argoproj.io" is forbidden: ... GUARDRAIL DENIED: deleting critical customresourcedefinitions applications.argoproj.io ...
$ as-admin -n openshift-gitops-operator delete subscription openshift-gitops-operator --dry-run=server
→ Error from server (Forbidden): ... GUARDRAIL DENIED: deleting critical subscriptions openshift-gitops-operator/openshift-gitops-operator ...
$ as-admin -n openshift-gitops-operator delete csv -l operators.coreos.com/openshift-gitops-operator.openshift-gitops-operator --dry-run=server
→ Error from server (Forbidden): ... clusterserviceversions ...
```

**T3.7 – the guardrail itself (self-protection; records residual risk R3).**
```bash
$ as-admin delete validatingadmissionpolicybinding guardrails-critical-delete-named --dry-run=server
→ EITHER  Error from server (Forbidden): ... GUARDRAIL DENIED: deleting critical validatingadmissionpolicybindings guardrails-critical-delete-named ...
   OR     validatingadmissionpolicybinding.admissionregistration.k8s.io "guardrails-critical-delete-named" deleted (server dry run)
```
If the second: VAP on your build does not evaluate its own kind. Note it in `docs/01` R3 and `llm/memory.md`; then prove the compensating layers: as a non-admin, `as-a1 delete vapb guardrails-critical-delete-named --dry-run=server` → `Error from server (Forbidden): ... User "a1@example.com" cannot delete resource ...` (RBAC); and T8 (self-heal + alert).
```bash
$ as-admin delete guardrailconfig default --dry-run=server
→ Error from server (Forbidden): ... GUARDRAIL DENIED: deleting critical guardrailconfigs default ...
$ as-admin delete group gitops-deletion-approvers --dry-run=server
→ Error from server (Forbidden): ... GUARDRAIL DENIED: deleting critical groups gitops-deletion-approvers ...
$ as-admin delete clusterrolebinding guardrails-approvers --dry-run=server
→ Error from server (Forbidden): ... GUARDRAIL DENIED: deleting critical clusterrolebindings guardrails-approvers ...
```

**T3.8 – downgrading the audit profile needs approvals.**
```bash
$ as-admin patch apiserver cluster --type merge -p '{"spec":{"audit":{"profile":"Default"}}}' --dry-run=server
→ (phase ≤ 3) apiserver.config.openshift.io/cluster patched (server dry run)   + audit annotation direct-mutation; Teams: ArgoCDDirectMutation
→ (phase 4)   Error from server (Forbidden): ... guardrails-gitops-only-mutation ... may only be changed through Git
```
Either way, a real (non-dry-run) change raises `AuditProfileChanged` (critical) within ~1 min.

**T3.9 – the audit forwarder and the alert rules.**
```bash
$ as-admin -n openshift-logging delete clusterlogforwarder audit-forwarder --dry-run=server
→ Error from server (Forbidden): ... GUARDRAIL DENIED: deleting critical clusterlogforwarders openshift-logging/audit-forwarder ...
$ as-admin -n openshift-logging delete alertingrule guardrails-audit-alerts --dry-run=server
→ Error from server (Forbidden): ... GUARDRAIL DENIED ...
```

**T3.10 – only trusted identities may mark an object critical.**
```bash
$ as-admin -n $NS create configmap tenant --from-literal=a=b
$ as-req -n $NS label configmap tenant $PFX/critical=true
→ Error from server (Forbidden): configmaps "tenant" is forbidden: ValidatingAdmissionPolicy 'guardrails-critical-label-control' with binding 'guardrails-critical-label-control' denied request: GUARDRAIL DENIED: only Argo CD, break-glass or members of gitops-deletion-approvers may mark an object as critical ...
$ as-a1 -n $NS label configmap tenant $PFX/critical=true
→ configmap/tenant labeled
```
(cluster-admin without approver membership is denied too; Argo CD applying the label from Git is allowed.)

## 4. Forged, duplicate and out-of-order approvals are rejected ★

**T4.1 – admin writes two approvals directly.**
```bash
$ as-admin -n $NS annotate configmap victim --overwrite "$PFX/delete-approvals=a1@example.com|$(ts),a2@example.com|$(ts)"
→ Error from server (Forbidden): ... denied request: GUARDRAIL DENIED: invalid change to guardrails.example.com/delete-approvals by admin@example.com. Rules: append exactly one entry "<your-username>|<RFC3339 UTC>", be a member of gitops-deletion-approvers, not be the requester, not approve twice, change nothing else in the object. Clearing the annotation is always allowed.
```

**T4.2 – request opened in someone else's name.**
```bash
$ as-req -n $NS annotate configmap victim --overwrite "$PFX/delete-request=CHG1: test" "$PFX/delete-requested-by=a1@example.com"
→ Error from server (Forbidden): ... GUARDRAIL DENIED: invalid deletion request change by req@example.com. delete-requested-by must equal your username, you must be in gitops-deletion-requesters,gitops-operators,gitops-deletion-approvers, delete-request must be non-empty, approvals must be empty when the request changes, and nothing else may change.
```

**T4.3 – request by someone outside the requester/approver groups** (use any ordinary user, e.g. `dev@example.com` with `patch` rights via a test RoleBinding, or skip if none).
```bash
$ KUBECONFIG=~/.kube/dev.kubeconfig oc -n $NS annotate configmap victim --overwrite "$PFX/delete-request=CHG1: x" "$PFX/delete-requested-by=dev@example.com"
→ Error from server (Forbidden): ... invalid deletion request change by dev@example.com ...   (or an RBAC Forbidden if the user has no patch rights: also a pass)
```

**T4.4 – approval before any request exists.**
```bash
$ as-a1 -n $NS annotate configmap victim --overwrite "$PFX/delete-approvals=a1@example.com|$(ts)"
→ Error from server (Forbidden): ... GUARDRAIL DENIED: invalid change to guardrails.example.com/delete-approvals by a1@example.com ...
```

**T4.5 – a valid request (positive).**
```bash
$ as-req -n $NS annotate configmap victim --overwrite "$PFX/delete-request=CHG1: guardrail test" "$PFX/delete-requested-by=req@example.com"
→ configmap/victim annotated
$ state victim
→ guardrails.example.com/delete-request=CHG1: guardrail test
  guardrails.example.com/delete-requested-by=req@example.com
```
Teams: `CriticalDeletionApprovalRecorded` (info, batched up to 1 min).

**T4.6 – requester approves own request.**
```bash
$ as-req -n $NS annotate configmap victim --overwrite "$PFX/delete-approvals=req@example.com|$(ts)"
→ Error from server (Forbidden): ... invalid change to guardrails.example.com/delete-approvals by req@example.com ...
```

**T4.7 – approver approves under another approver's name.**
```bash
$ as-a1 -n $NS annotate configmap victim --overwrite "$PFX/delete-approvals=a2@example.com|$(ts)"
→ Error from server (Forbidden): ... invalid change ... by a1@example.com ...
```

**T4.8 – approval with a malformed entry.**
```bash
$ as-a1 -n $NS annotate configmap victim --overwrite "$PFX/delete-approvals=a1@example.com"
→ Error from server (Forbidden): ... invalid change ...          (missing |timestamp)
$ as-a1 -n $NS annotate configmap victim --overwrite "$PFX/delete-approvals=a1@example.com|yesterday"
→ Error from server (Forbidden): ... invalid change ...          (timestamp not RFC3339 UTC)
```

**T4.9 – approval that also changes data (smuggled change).**
```bash
$ as-a1 -n $NS patch configmap victim --type merge -p "{\"metadata\":{\"annotations\":{\"$PFX/delete-approvals\":\"a1@example.com|$(ts)\"}},\"data\":{\"a\":\"hacked\"}}"
→ Error from server (Forbidden): ... invalid change to guardrails.example.com/delete-approvals by a1@example.com ... change nothing else in the object ...
```

**T4.10 – approver 1 approves correctly (positive).**
```bash
$ as-a1 -n $NS annotate configmap victim --overwrite "$PFX/delete-approvals=a1@example.com|$(ts)"
→ configmap/victim annotated
$ state victim | grep approvals
→ guardrails.example.com/delete-approvals=a1@example.com|2026-09-18T10:20:31Z
```

**T4.11 – delete with only one approval.**
```bash
$ as-req -n $NS delete configmap victim
→ Error from server (Forbidden): ... GUARDRAIL DENIED: deleting critical configmaps guardrails-test/victim requires a delete-request and at least 2 distinct approvals from gitops-deletion-approvers (found 1, requested-by=req@example.com, executor may not be an approver) ...
```

**T4.12 – same approver twice (second entry, different timestamp).**
```bash
$ CUR=$(as-a1 -n $NS get cm victim -o go-template="{{index .metadata.annotations \"$PFX/delete-approvals\"}}")
$ as-a1 -n $NS annotate configmap victim --overwrite "$PFX/delete-approvals=$CUR,a1@example.com|$(ts)"
→ Error from server (Forbidden): ... invalid change ... not approve twice ...
```

**T4.13 – approver 2 replaces the list instead of appending (drops approver 1).**
```bash
$ as-a2 -n $NS annotate configmap victim --overwrite "$PFX/delete-approvals=a2@example.com|$(ts)"
→ Error from server (Forbidden): ... invalid change ... append exactly one entry ...
```

**T4.14 – approver 2 approves correctly (positive).**
```bash
$ as-a2 -n $NS annotate configmap victim --overwrite "$PFX/delete-approvals=$CUR,a2@example.com|$(ts)"
→ configmap/victim annotated
$ state victim | grep approvals
→ guardrails.example.com/delete-approvals=a1@example.com|...Z,a2@example.com|...Z
```

**T4.15 – an approver executes.**
```bash
$ as-a1 -n $NS delete configmap victim
→ Error from server (Forbidden): ... GUARDRAIL DENIED: ... (found 2, requested-by=req@example.com, executor may not be an approver) ...
```
(RBAC may already return `User "a1@example.com" cannot delete resource "configmaps"` because approvers have no `delete` verb: also a pass. To exercise the policy rule itself, temporarily bind `guardrails-executor` to a1 in the scratch namespace.)

**T4.16 – requester edits the reason after approvals.**
```bash
$ as-req -n $NS annotate configmap victim --overwrite "$PFX/delete-request=CHG1: changed my mind"
→ Error from server (Forbidden): ... invalid deletion request change by req@example.com ... approvals must be empty when the request changes ...
```

## 5. The happy path ★

**T5.1 – executor deletes with two approvals.**
```bash
$ as-req -n $NS delete configmap victim
→ configmap "victim" deleted
```
Audit tail:
```
→ delete victim by req@example.com rc=200 :: op=DELETE user=req@example.com groups=... requestedBy=req@example.com approvers=a1@example.com|a2@example.com approved=true exempt=false ::
```
Teams **and** email within ~60 s: 🔴 `[FIRING] CriticalResourceDeleted - configmaps guardrails-test/victim`, actor `req@example.com`, runbook link. Record the delta between the audit timestamp and the Teams post (target ≤ 60 s).

**T5.2 – the same with the scripts (repeat with a fresh `victim`).**
```bash
$ as-admin -n $NS create configmap victim --from-literal=a=b && as-admin -n $NS label configmap victim $PFX/critical=true
$ KUBECONFIG=~/.kube/req.kubeconfig scripts/request-deletion.sh configmap victim -n $NS "CHG2: script test"
→ Opening deletion request on configmap/victim as req@example.com
  Request recorded. Ask 2 members of gitops-deletion-approvers (not yourself) to run:
    ./approve-deletion.sh configmap victim -n guardrails-test
  Resource     : configmap/victim -n guardrails-test
  critical     : true
  request      : CHG2: script test
  requested-by : req@example.com
  approvals    : <none>
$ KUBECONFIG=~/.kube/a1.kubeconfig scripts/approve-deletion.sh configmap victim -n $NS      # type: approve
→ Approval recorded at 2026-...Z
$ KUBECONFIG=~/.kube/a2.kubeconfig scripts/approve-deletion.sh configmap victim -n $NS      # type: approve
→ Approval recorded at 2026-...Z
$ KUBECONFIG=~/.kube/req.kubeconfig scripts/execute-deletion.sh configmap victim -n $NS     # type: victim
→ Deleted. Expect CriticalResourceDeleted (email + Teams) within ~60s.
  Audit trail (Loki / logcli): ...
```
Negative checks built into the scripts: `approve-deletion.sh` as `req` → `You opened this request (req@example.com); you cannot approve it.`; `execute-deletion.sh` with one approval → `Only 1 distinct approvals, 2 required. Deletion will be denied.`

## 6. Cancel and expiry ★

**T6.1 – cancel clears everything; delete after cancel is denied.**
```bash
$ as-admin -n $NS create configmap victim2 --from-literal=a=b && as-admin -n $NS label configmap victim2 $PFX/critical=true
$ as-req -n $NS annotate configmap victim2 --overwrite "$PFX/delete-request=CHG3: cancel test" "$PFX/delete-requested-by=req@example.com"
$ as-a1  -n $NS annotate configmap victim2 --overwrite "$PFX/delete-approvals=a1@example.com|$(ts)"
$ as-a2  -n $NS annotate configmap victim2 --overwrite "$PFX/delete-request-" "$PFX/delete-requested-by-" "$PFX/delete-approvals-"
→ configmap/victim2 annotated              (anyone with patch rights may cancel; cancelling never makes deletion easier)
$ as-req -n $NS delete configmap victim2
→ Error from server (Forbidden): ... GUARDRAIL DENIED: ... (found 0, requested-by=, ...)
```

**T6.2 – the reaper removes expired approvals and cannot add any.**
```bash
$ as-req -n $NS annotate configmap victim2 --overwrite "$PFX/delete-request=CHG4: reaper" "$PFX/delete-requested-by=req@example.com"
$ as-a1  -n $NS annotate configmap victim2 --overwrite "$PFX/delete-approvals=a1@example.com|$(ts)"
# simulate expiry: the reaper SA may only REMOVE, so an old entry must be created by an approver (an old timestamp is a valid RFC3339 value)
$ as-a2  -n $NS annotate configmap victim2 --overwrite "$PFX/delete-approvals=a1@example.com|2000-01-01T00:00:00Z,a2@example.com|$(ts)"
→ Error from server (Forbidden): ... (a2 tried to change a1's entry: correct)
$ as-a2  -n $NS annotate configmap victim2 --overwrite "$PFX/delete-approvals=$(as-a2 -n $NS get cm victim2 -o go-template="{{index .metadata.annotations \"$PFX/delete-approvals\"}}"),a2@example.com|2000-01-01T00:00:00Z"
→ configmap/victim2 annotated
$ as-admin -n guardrails-system create job reaper-manual --from=cronjob/approval-reaper
$ as-admin -n guardrails-system wait --for=condition=complete job/reaper-manual --timeout=120s
$ as-admin -n guardrails-system logs job/reaper-manual
→ reaper start ttl=4h (14400s) now=...
  expire configmaps guardrails-test/victim2 approver=a2@example.com at=2000-01-01T00:00:00Z
  configmap/victim2 annotated
  reaper done
$ state victim2 | grep approvals
→ guardrails.example.com/delete-approvals=a1@example.com|...Z          (only the fresh entry remains)
$ as-admin --as=system:serviceaccount:guardrails-system:approval-reaper -n $NS annotate configmap victim2 --overwrite "$PFX/delete-approvals=a1@example.com|$(ts),a2@example.com|$(ts)"
→ Error from server (Forbidden): ... invalid change ... by system:serviceaccount:guardrails-system:approval-reaper ...   (reaper cannot add)
$ as-admin -n guardrails-system delete job reaper-manual
```
(The `--as` in the last step raises `ImpersonationUsed`; expected during testing.)

## 7. Git-side deletion cannot bypass ★

**T7.1 – a manifest removed from Git is not pruned, and a forced prune is denied.**
1. Open a PR that deletes `manifests/03-guardrails/vap-critical-delete-bindings.yaml`. CI step "guardrail invariants" → **fails** (`grep -q '"Deny"'`). Expected: the PR cannot merge under the ruleset.
2. To test the cluster side without merging a bad PR, use a scratch labelled object managed by a scratch Application (or temporarily add `victim3` to a kustomization in a test branch pointed to by a test Application with `prune: true`). Remove it from the branch, sync with prune:
```bash
$ argocd app sync <test-app> --prune
→ ... Message: configmaps "victim3" is forbidden: ValidatingAdmissionPolicy 'guardrails-critical-delete' ... GUARDRAIL DENIED ...
  FATAL: ... one or more objects failed to apply
$ as-admin -n $NS get cm victim3
→ NAME      DATA   AGE          (still present)
```
Teams: `CriticalResourceDeleteDenied` with actor `system:serviceaccount:openshift-gitops:openshift-gitops-argocd-application-controller`.

**T7.2 – the guardrails Application itself has no cascade finalizer and prune off.**
```bash
$ as-admin -n openshift-gitops get application guardrails -o jsonpath='{.metadata.finalizers} {.spec.syncPolicy.automated.prune} {.spec.syncPolicy.syncOptions}{"\n"}'
→  false ["Prune=false","ServerSideApply=true","ApplyOutOfSyncOnly=true","RespectIgnoreDifferences=true","PruneLast=true"]
```

## 8. Self-healing of the control ★

**T8.1 – an out-of-band edit is reverted and alerted.** (Needs break-glass or the Argo CD SA in phases ≥ 3 because the binding is critical; in phase 1/2 an admin can do it directly. Use the least-privileged path available and document it.)
```bash
$ as-admin patch validatingadmissionpolicybinding guardrails-critical-delete-named --type merge -p '{"spec":{"validationActions":["Audit"]}}'
→ validatingadmissionpolicybinding.admissionregistration.k8s.io/guardrails-critical-delete-named patched   (phase 1/2)
   or Error from server (Forbidden): ... guardrails-gitops-only-mutation ...                                   (phase 4)
$ sleep 200; as-admin get vapb guardrails-critical-delete-named -o jsonpath='{.spec.validationActions}{"\n"}'
→ ["Deny","Audit"]       (Argo CD self-heal restored it; check `argocd app history guardrails`)
```
Teams/email: 🔴 `GuardrailPolicyModified` naming the actor within ~1 min.

## 9. Alert delivery ★

**T9.1 – synthetic alert (no cluster change).**
```bash
$ as-admin -n openshift-monitoring exec alertmanager-main-0 -c alertmanager -- amtool --alertmanager.url=http://localhost:9093 alert add \
    alertname=CriticalResourceDeleted severity=critical guardrail=true team=platform-engineering \
    objectRef_resource=configmaps objectRef_namespace=guardrails-test objectRef_name=synthetic user_username=tester@example.com \
    --annotation=summary="SYNTHETIC test alert - ignore" --annotation=description="delivery test" --annotation=runbook_url=https://example
```
→ Teams card `🔴 [FIRING] CriticalResourceDeleted - configmaps guardrails-test/synthetic` and an email with subject `[FIRING:1] 🔴 CriticalResourceDeleted - configmaps guardrails-test/synthetic` within ~10 s. After `resolve_timeout` (5 min) both channels receive `[RESOLVED]`.
```bash
$ as-admin -n openshift-monitoring exec alertmanager-main-0 -c alertmanager -- amtool --alertmanager.url=http://localhost:9093 alert query alertname=CriticalResourceDeleted
→ Alertname                 Starts At                Summary
  CriticalResourceDeleted   2026-09-18 10:41:02 UTC  SYNTHETIC test alert - ignore
```

**T9.2 – real alert timing.** Use T5.1. Record: audit `requestReceivedTimestamp`, alert `startsAt` (`amtool alert query`), Teams post time. Target ≤ 60 s.

**T9.3 – repeat and inhibition.** Leave the T5.1 alert unresolved: a second Teams post arrives after 30 min (`repeat_interval`). Fire T3.1 for the same object name while `CriticalResourceDeleted` is active: no separate `CriticalResourceDeleteDenied` post (inhibited).

## 10. Detection pipeline blind spot ★

**T10.1 – stopping audit forwarding is itself alerted from the metrics pipeline.**
```bash
$ as-admin -n openshift-logging patch clusterlogforwarder audit-forwarder --type merge -p '{"spec":{"managementState":"Unmanaged"}}'
→ (phase ≥ 3: this is a critical object; the patch is flagged/denied by gitops-only-mutation depending on phase. If denied, use the workflow or break-glass in pre-prod only.)
$ as-admin -n openshift-logging delete daemonset audit-forwarder
$ sleep 660
```
→ Teams/email: 🔴 `AuditLogIngestionStalled` ("No audit log lines reached Loki for 10 minutes") plus `AuditForwarderChanged` from the earlier patch. Restore: `managementState: Managed`; the operator recreates the DaemonSet; the alert resolves within ~5 min.

## 11. Repository controls

**T11.1 – ruleset.**
```bash
$ gh api repos/example-org/openshift-administration/rules/branches/main --jq '.[].type'
→ deletion
  non_fast_forward
  required_linear_history
  required_signatures
  pull_request
  required_status_checks
```
**T11.2 – a PR that adds a human to `exemptUsers`** → CI `guardrail invariants` fails; CODEOWNERS requires `@example-org/security`; one approval is not enough to merge.

## 12. Impersonation is loud ★

```bash
$ as-admin --as=a1@example.com --as-group=gitops-deletion-approvers -n $NS annotate configmap victim2 --overwrite "$PFX/delete-approvals=a1@example.com|$(ts)"
→ configmap/victim2 annotated     (cluster-admin CAN impersonate: this is residual risk R1)
```
→ Teams/email (security): 🔴 `ImpersonationUsed`: `admin@example.com impersonated a1@example.com for a write (patch configmaps)` within ~1 min. Audit tail shows `imp=a1@example.com`. This is the proof that a forged approval is always attributable.

## 13. Break-glass

Two custodians, an incident ticket, pre-prod.
```bash
$ as-admin -n guardrails-system create token breakglass --duration=10m > /dev/shm/bg
$ oc --token="$(cat /dev/shm/bg)" --server=https://api.<cluster>:6443 -n $NS delete configmap victim2
→ configmap "victim2" deleted     (no approvals needed: exempt identity)
$ rm -f /dev/shm/bg
```
→ Teams/email (security): 🔴 `BreakGlassUsed` for every request made with the token; `CriticalResourceDeleted` with `exempt=true` in the decision annotation.

## 14. Privileged RBAC and group changes ★

```bash
$ as-admin create clusterrolebinding test-ca --clusterrole=cluster-admin --user=someone@example.com
→ Warning: Validation failed for ValidatingAdmissionPolicy 'guardrails-rbac-escalation-audit' with binding 'guardrails-rbac-escalation-audit': FLAGGED FOR AUDIT (not blocked): privileged RBAC/group change by admin@example.com on clusterrolebindings test-ca. A security alert has been raised.
  clusterrolebinding.rbac.authorization.k8s.io/test-ca created
$ as-admin delete clusterrolebinding test-ca
→ Warning: ... FLAGGED FOR AUDIT ...
  clusterrolebinding.rbac.authorization.k8s.io "test-ca" deleted
```
→ Teams/email (security): 🔴 `PrivilegedRBACChange` for both operations.

## 15. Phase-2 behaviour (warn) — run once during phase 2

```bash
$ as-admin -n $NS delete configmap victim --dry-run=server
→ Warning: Validation failed for ValidatingAdmissionPolicy 'guardrails-critical-delete' with binding 'guardrails-critical-delete-labelled': GUARDRAIL DENIED: deleting critical configmaps guardrails-test/victim requires ...
  configmap "victim" deleted (server dry run)
```
Pass = the warning text is shown **and** the request succeeds.

## 16. Backup and restore

```bash
$ as-admin -n openshift-adp create backup drill-$(date +%Y%m%d) --from-schedule=gitops-6h
$ as-admin -n openshift-adp get backup drill-$(date +%Y%m%d) -o jsonpath='{.status.phase} items={.status.progress.itemsBackedUp}{"\n"}'
→ Completed items=137
```
Restore into a mapped namespace as in docs/07 → `Restore ... phase=Completed errors=0`; `oc get application,appproject,secret -n gitops-drill` lists the objects; delete `gitops-drill`.

## 17. Cleanup and results

```bash
# The scratch namespace itself is not critical, so its deletion is accepted:
$ as-admin delete ns $NS
→ namespace "guardrails-test" deleted
$ as-admin get ns $NS
→ NAME              STATUS        AGE
  guardrails-test   Terminating   30s
```
The namespace stays `Terminating` because the namespace controller's deletes of the labelled ConfigMaps are **denied** (the controller is not exempt). Audit tail: `delete victim2 by system:serviceaccount:kube-system:namespace-controller rc=403 :: ... approved=false ...`. This is intentional and worth showing reviewers: a namespace deletion cannot take a critical object with it. To finish the cleanup, run the full workflow (T5) on each remaining critical ConfigMap, or clear the label through the workflow; in pre-prod, break-glass (T13) is acceptable. The namespace then finishes terminating within a minute.

| ID | Scenario | Expected | Result | Evidence (audit line / screenshot) | Tester | Date |
|---|---|---|---|---|---|---|
| T1.1 | phase-1 annotated, not blocked | rc=200 + validation_failure | | | | |
| T2.1 | non-critical delete | allowed | | | | |
| T3.1–T3.9 | single-identity deletes | all denied | | | | |
| T3.10 | label control | requester denied, approver allowed | | | | |
| T4.1–T4.16 | forged/invalid approvals | denied except 4.5, 4.10, 4.14 | | | | |
| T5.1–T5.2 | happy path | deleted + red alert ≤ 60 s | | | | |
| T6.1–T6.2 | cancel, reaper | as described | | | | |
| T7.1–T7.2 | Git-side | prune denied, no finalizer | | | | |
| T8.1 | self-heal | reverted + alert | | | | |
| T9.1–T9.3 | delivery | Teams + email, repeat, inhibit | | | | |
| T10.1 | ingestion stalled | metrics alert | | | | |
| T11 | repo controls | ruleset + CI | | | | |
| T12 | impersonation | alert | | | | |
| T13 | break-glass | works + alert | | | | |
| T14 | privileged RBAC | warning + alert | | | | |
| T15 | phase-2 warning | warning + success | | | | |
| T16 | backup/restore | Completed | | | | |

Sign-off requires every row filled, zero unexpected results, and the evidence attached to the change ticket for the next phase.
