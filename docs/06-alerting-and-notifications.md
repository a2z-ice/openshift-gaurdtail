# 06 · Alerting and notifications (email + Microsoft Teams)

## Why two detection pipelines

| Pipeline | Source | Catches | Blind when |
|---|---|---|---|
| **Audit** (Loki `AlertingRule`s, tenant `audit`) | every API request, incl. denied ones, with the actor | deletions, denied attempts, approvals, guardrail/RBAC/audit tampering, impersonation, break-glass, kubeadmin, node access | audit forwarding is stopped |
| **Metrics** (`PrometheusRule`s, platform Prometheus) | kube-state-metrics, Argo CD metrics, Loki metrics | Argo CD gone / 0 replicas / no apps, namespace Terminating, operator missing, **audit ingestion stalled**, Loki ruler down, reaper failing | Prometheus itself is down (which OpenShift alerts on separately via `Watchdog`) |

Each covers the other's failure mode: stop the forwarder and `AuditLogIngestionStalled` fires from metrics; delete Argo CD and both `CriticalResourceDeleted` (audit) and `ArgoCDApplicationControllerMissing` (metrics) fire.

## Alert catalogue

| Alert | Pipeline | Severity | Channel | Meaning |
|---|---|---|---|---|
| `CriticalResourceDeleted` | audit | critical | email + Teams, repeat 30 m | a critical object was deleted **out of band** (workflow-approved or exempt). Verify the approvals; restore if unexpected |
| `GitOpsCriticalDeletionApplied` | audit | warning | Teams | Argo CD pruned a critical object from Git; must correlate with a merged PR |
| `CriticalDeleteWouldBeDenied` | audit | warning | Teams | phase 1/2 only: the request succeeded but would be denied in phase 3 (rollout signal) |
| `ArgoCDCredentialSecretDeleted` | audit | critical | email + Teams | a Secret in openshift-gitops was deleted by a non-system identity (Tier B: only JIT admin or break-glass can) |
| `PrivilegedIdentityImpersonated` | audit | critical | security | someone impersonated break-glass or an Argo CD controller (the one-command bypass) |
| `PrivilegedTokenMinted` | audit | critical | security | a token was minted for break-glass, the reaper or an Argo CD SA |
| `ImpersonatedWriteDenied` | audit | critical | security | a non-dry-run write under impersonation was blocked (docs/17) |
| `GitOpsResourceDeleted` | audit | critical | email + Teams | name-based fallback for GitOps namespaces/kinds, independent of the policy |
| `CriticalResourceDeleteDenied` | audit | warning | Teams | blocked attempt; who and what |
| `CriticalDeletionRequested` | audit (tracker) | info | **approvers** email + Teams, immediate | a deletion request was opened: who, what, reason, approvals needed, request expiry, approve command (docs/19) |
| `CriticalDeletionApproved` | audit (tracker) | info | **approvers** | approval *have* of *need*, remaining or FULLY APPROVED, oldest approval expiry |
| `CriticalDeletionApprovalsExpired` | audit (tracker) | info | **approvers** | the reaper removed approvals older than `approvalTTL` |
| `CriticalDeletionRequestClosed` | audit (tracker) | info | **approvers** | cancelled, request expired (`requestTTL`), approvals cleared, or executed |
| `CriticalDeletionPendingApproval` | audit (tracker, last state) | info | **approvers**, hourly | reminder: an open request still needs approvals |
| `CriticalDeletionAwaitingExecution` | audit (tracker, last state) | info | **approvers**, hourly | reminder: fully approved but not executed |
| `GuardrailReaperNotRunning` | metrics | warning | Teams | no reaper run completed for 30 min, CronJob suspended or missing: expiry is not enforced |
| `CriticalDeletionApprovalRecorded` | audit | info | Teams (batched) | request/approval activity; expected during a planned deletion |
| `GuardrailPolicyModified` | audit | critical | email + Teams | policy/binding/config/RBAC/reaper changed by anyone but Argo CD |
| `AuditProfileChanged` | audit | critical | email + Teams | `APIServer/cluster` changed out of band |
| `AuditForwarderChanged` | audit | critical | email + Teams | forwarder / LokiStack / rules changed out of band |
| `PrivilegedRBACChange` | audit | critical | email + Teams (security) | binding to cluster-admin or privileged group membership changed |
| `ImpersonationUsed` | audit | critical | security | any write via `--as` |
| `BreakGlassUsed` | audit | critical | security | the exempt SA made any request |
| `KubeadminOrSystemAdminUsed` | audit | critical | security | write by `kube:admin` / `system:admin` |
| `ArgoCDDirectMutation` | audit | warning | Teams | human edited a critical object directly (denied in phase 4) |
| `ControlPlaneNodeAccess` | audit | critical | security | exec/debug in control-plane namespaces by a human |
| `ArgoCDApplicationControllerMissing` / `ArgoCDServerMissing` / `ArgoCDNoApplicationsReported` / `GitOpsOperatorMissing` | metrics | critical | email + Teams | Argo CD availability |
| `GitOpsNamespaceTerminating` | metrics | critical | email + Teams | protected namespace is being deleted |
| `GuardrailApplicationOutOfSyncOrMissing` | metrics | warning | Teams | self-heal not working |
| `AuditLogIngestionStalled` / `AuditForwarderNotReady` / `LokiRulerDown` | metrics | critical/warning | email + Teams | detection pipeline health |
| `GuardrailReaperFailing` | metrics | warning | Teams | TTL enforcement not running |
| `GuardrailPolicyEvaluationErrors` / `GuardrailPolicyNotEvaluating` / `GuardrailPolicySlow` | metrics | critical/warning | email + Teams | kube-apiserver VAP metrics: CEL errors, cost-budget exhaustion, policy missing, slow |
| `GuardrailNotificationFailing` / `GuardrailAlertmanagerConfigInvalid` | metrics | critical | email + Teams | Teams/SMTP delivery failing or Alertmanager config not loading |

Every alert carries `guardrail="true"`, `severity`, `team`, a `summary`, a `description` with actor/object, and a `runbook_url` into docs/09.

## Routing (`manifests/05-alerting/alertmanager-main.yaml`)

```
route guardrail="true" & audience="approvers" → receiver guardrail-approvers group_wait 0s, group_interval 1m, repeat 1h (no continue: workflow messages, docs/19)
route guardrail="true" & severity="critical"  → receiver guardrail-red        group_wait 0s, group_interval 1m, repeat 30m, continue
route guardrail="true" & severity="warning"   → receiver guardrail-teams-only group_wait 15s, repeat 4h, continue
route guardrail="true" & severity="info"      → receiver guardrail-teams-only group_wait 1m, group_interval 10m
route guardrail="true"                        → receiver default (your existing on-call path, so nothing is lost if Teams/SMTP fail)
```

Inhibition: a confirmed `CriticalResourceDeleted` silences `CriticalResourceDeleteDenied` for the same object.

Receivers: `guardrail-red` = `email_configs` (HTML template, `X-Priority: 1`) + `msteamsv2_configs`; `guardrail-teams-only` = Teams only; `guardrail-approvers` = the approvers' distribution list + the approvers' Teams channel (a second Workflows webhook), `send_resolved: false`. The templates print approval progress (have of need, remaining, requester, expiries) when those labels are present. Templates live in the `guardrail.tmpl` key of the same secret and are referenced as `/etc/alertmanager/config/guardrail.tmpl` (the Prometheus Operator mounts every key of `alertmanager-main` there).

## Microsoft Teams setup (Workflows, not the retired O365 connector)

Alertmanager ≥ 0.28 speaks the Teams *Workflows* (Power Automate) format natively (`msteamsv2_configs`); OCP 4.21 ships 0.29.0. No `prometheus-msteams` bridge.

1. In Teams, open the target channel → `…` → **Workflows** → search "Post to a channel when a webhook request is received" → select the team and channel → **Add workflow**. Copy the HTTP POST URL (`https://prod-XX.<region>.logic.azure.com:443/workflows/<id>/triggers/manual/paths/invoke?...&sig=...`).
2. In Power Automate, open the flow and confirm the "Post card in a chat or channel" step posts **as Flow bot** with the adaptive card from the request body (the default template does).
3. Store the URL in the vault; inject it into `alertmanager-main` (both `webhook_url` occurrences). The `sig=` query parameter is the secret: treat the URL as a credential (GitHub push protection is enabled in docs/08 for exactly this).
4. Optional: a second workflow/channel for `team="security"` alerts; add a route with `team="security"` above the generic one.

Test from inside the cluster without waiting for a real alert:

```bash
oc -n openshift-monitoring exec alertmanager-main-0 -c alertmanager -- \
  amtool --alertmanager.url=http://localhost:9093 alert add \
  alertname=CriticalResourceDeleted severity=critical guardrail=true team=platform-engineering \
  objectRef_resource=configmaps objectRef_namespace=guardrails-test objectRef_name=synthetic user_username="$(oc whoami)" \
  --annotation=summary="SYNTHETIC test alert - ignore" --annotation=description="Fired by $(oc whoami) to verify Teams + email delivery" \
  --annotation=runbook_url=https://github.com/example-org/openshift-administration/blob/main/docs/09-runbooks.md
```

Expected: Teams card and email within ~10 s (group_wait 0). Then `amtool alert query` and `amtool silence add alertname=CriticalResourceDeleted objectRef_name=synthetic -d 5m -c test`.

## Email (SMTP)

`global.smtp_*` in the Alertmanager config; use a relay that requires TLS and authentication; the password comes from the vault. Distribution lists (`platform-oncall@`, `security-oncall@`) rather than individuals. Consider an additional `email_configs` entry to your ticketing system's mail-to-ticket address so every red alert opens an incident automatically.

## Installing the Alertmanager config

```bash
# render the two keys with the real secrets (from vault) into a temp dir, then:
oc -n openshift-monitoring create secret generic alertmanager-main \
  --from-file=alertmanager.yaml=./alertmanager.yaml --from-file=guardrail.tmpl=./guardrail.tmpl \
  --dry-run=client -o yaml | oc replace -f -
oc -n openshift-monitoring label secret alertmanager-main guardrails.example.com/critical=true --overwrite
# validate
oc -n openshift-monitoring exec alertmanager-main-0 -c alertmanager -- amtool check-config /etc/alertmanager/config_out/alertmanager.env.yaml
oc -n openshift-monitoring logs alertmanager-main-0 -c alertmanager --since=2m | grep -i -E 'error|reload'
```

If your organisation forbids editing the platform Alertmanager, `alertmanagerconfig-uwm-alternative.yaml` documents the `AlertmanagerConfig` path and its limitations (namespace matcher, `enableUserAlertmanagerConfig`).

## Loki AlertingRules (`loki-alertingrules-audit.yaml`)

- `tenantID: audit`; namespace `openshift-logging` (must be labelled `openshift.io/cluster-monitoring=true`); object labelled `openshift.io/log-alerting=true` to match the LokiStack `rules.selector`.
- In `openshift-logging` tenant mode the Loki Operator wires the ruler to the platform Alertmanager automatically (`RulerConfig` only needed for a non-default Alertmanager).
- Rules use `count_over_time(... [2m]) > 0`, `interval: 30s`, `for: 0s` → worst-case detection latency ≈ 30 s + ingestion (~5–10 s). Rules on writes filter `objectRef_subresource=""` so controller status updates never page, and every rule excludes the known system identities (Argo CD SAs, kube-system controllers, logging operators, group sync).
- Field names come from Loki's `json` parser (see docs/02). After a Logging major upgrade re-run `scripts/test-guardrails.sh` to prove the rules still match.

## Verification

```bash
oc get alertingrule -n openshift-logging guardrails-audit-alerts -o jsonpath='{.status.conditions}'; echo
oc -n openshift-logging logs -l app.kubernetes.io/component=ruler --tail=50 | grep -i guardrails
oc get prometheusrule -n openshift-gitops guardrails-gitops-health
# rules loaded in Prometheus?
oc -n openshift-monitoring exec -c prometheus prometheus-k8s-0 -- curl -s 'http://localhost:9090/api/v1/rules' | grep -o 'ArgoCDApplicationControllerMissing' | head -1
# fire a real one: delete a labelled scratch configmap through the workflow (docs/11) and time the Teams post
```
