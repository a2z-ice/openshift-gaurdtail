# 02 · Audit logging: profile, forwarding, retention, investigations

## Why

Every other control in this repository produces its evidence through the API-server audit log. If the audit log is incomplete, unattributable or mutable, the deletion guardrail still works but nobody can prove who did what, and the alerts cannot fire. OpenShift writes audit logs for three API servers (`kube-apiserver`, `openshift-apiserver`, `oauth-apiserver`) to the control-plane nodes; they are rotated locally and **must** be shipped off-node.

## Design

| Decision | Value | Rationale |
|---|---|---|
| Audit profile | `WriteRequestBodies` (all groups) | Metadata for every request, plus request **and response bodies** for create/update/patch/delete. Investigations need "what exactly changed", which `Default` (metadata only) cannot answer. `AllRequestBodies` also logs GET/LIST bodies: several × the volume and copies secret values into the log stream. Reads are still attributed at metadata level (who read which secret). |
| Sensitive kinds | Red Hat's profile keeps `secrets`, `configmaps`, `routes`, `oauthclients`, tokens at Metadata level even under `WriteRequestBodies` | Verify on your build: `oc get cm -n openshift-kube-apiserver kube-apiserver-audit-policies -o yaml \| grep -B2 -A6 secrets` |
| Custom rules | `system:authenticated:oauth`, `system:serviceaccounts:openshift-gitops`, `system:serviceaccounts:guardrails-system` → `WriteRequestBodies` | Explicit, so a future change of the top-level profile cannot silently drop bodies for humans or the GitOps controller |
| Transport | OpenShift Logging 6 (`ClusterLogForwarder`, Vector) | Supported, runs on control-plane nodes (toleration), at-least-once delivery with disk buffering |
| Outputs | **SIEM (Splunk HEC)** = system of record, 1–7 years, WORM index; **LokiStack audit tenant** = 90 days, only for alerting and quick investigations | Two destinations from one pipeline so a SIEM outage never blinds alerting and vice versa |
| Immutability | Loki S3 bucket and SIEM cold storage with Object Lock (compliance mode); LokiStack retention 90 d; nobody has `delete` on the buckets | Tamper evidence |
| Labels | `openshift.labels.cluster=<id>`, `environment` added by the forwarder | Multi-cluster SIEM correlation |

Disk impact on control-plane nodes: `WriteRequestBodies` roughly doubles audit volume versus `Default`. kube-apiserver keeps 10 files × 100 MB per API server by default; with Vector shipping continuously this is fine on the standard 120 GB control-plane disks. Watch `node_filesystem_avail_bytes{mountpoint="/var"}` on masters for a week after enabling.

## The audit event, and the fields every rule uses

```json
{
  "kind": "Event", "level": "RequestResponse", "auditID": "…", "stage": "ResponseComplete",
  "requestURI": "/apis/argoproj.io/v1beta1/namespaces/openshift-gitops/argocds/openshift-gitops",
  "verb": "delete",
  "user": { "username": "alice@example.com", "groups": ["system:authenticated:oauth", "gitops-deletion-requesters"] },
  "impersonatedUser": { "username": "approver1@example.com" },           // only when --as was used
  "sourceIPs": ["10.0.12.7"], "userAgent": "oc/4.21.0 …",
  "objectRef": { "resource": "argocds", "namespace": "openshift-gitops", "name": "openshift-gitops", "apiGroup": "argoproj.io", "apiVersion": "v1beta1" },
  "responseStatus": { "code": 403, "reason": "Forbidden" },
  "requestObject": { … },  "responseObject": { … },
  "requestReceivedTimestamp": "2026-09-18T10:15:02.123456Z", "stageTimestamp": "…",
  "annotations": {
    "authorization.k8s.io/decision": "allow",
    "authorization.k8s.io/reason": "RBAC: allowed by ClusterRoleBinding \"guardrails-executors\" …",
    "guardrails-critical-delete/decision": "op=DELETE user=alice@example.com groups=… requestedBy=… approvers=… approved=false exempt=false",
    "validation.policy.admission.k8s.io/validation_failure": "[{\"message\":\"GUARDRAIL DENIED: …\",\"policy\":\"guardrails-critical-delete\",\"binding\":\"guardrails-critical-delete-named\",\"expressionIndex\":0,\"validationActions\":[\"Deny\",\"Audit\"]}]"
  }
}
```

The two `annotations` written by the policies are what make alerting precise: `guardrails-critical-delete/decision` is present on **every** evaluated request against a critical object (allowed or denied) and carries the approvers list; `validation_failure` is present when a validation failed and the binding had `Audit` in `validationActions`.

Loki's `json` parser flattens nested keys with `_` and replaces non-alphanumerics: `user.username` → `user_username`, `annotations["guardrails-critical-delete/decision"]` → `annotations_guardrails_critical_delete_decision`.

## Manifests

- `manifests/01-audit/apiserver-audit.yaml` – the `APIServer/cluster` patch. Applying it rolls the kube-apiserver pods one by one (10–15 min, no downtime). The object is critical: lowering the profile later needs approvals.
- `manifests/01-audit/operators.yaml` – Logging + Loki operators.
- `manifests/01-audit/lokistack.yaml` – `1x.small`, audit tenant retention 90 d, `rules.enabled` with selectors so the ruler loads `AlertingRule`s labelled `openshift.io/log-alerting=true` from namespaces labelled `openshift.io/cluster-monitoring=true`.
- `manifests/01-audit/clusterlogforwarder-audit.yaml` – SA + two ClusterRoleBindings (`collect-audit-logs`, `logging-collector-logs-writer`), input `audit` with sources `kubeAPI, openshiftAPI, auditd, ovn`, outputs `siem-splunk` and `loki-audit`, one pipeline. Elasticsearch and syslog blocks are included commented out.

Secrets to create from the vault (never in Git): `openshift-logging/logging-loki-s3`, `openshift-logging/splunk-hec` (key `hecToken`), optional CA ConfigMaps.

## Verification

```bash
oc get apiserver cluster -o jsonpath='{.spec.audit}'; echo
oc get co kube-apiserver                                   # PROGRESSING=False after the roll
oc get clusterlogforwarder audit-forwarder -n openshift-logging -o jsonpath='{range .status.conditions[*]}{.type}={.status} {end}'; echo
oc get lokistack logging-loki -n openshift-logging -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'; echo
# audit lines flowing? (platform Prometheus)
oc -n openshift-monitoring exec -c prometheus prometheus-k8s-0 -- \
  curl -s 'http://localhost:9090/api/v1/query?query=sum(rate(loki_distributor_lines_received_total{tenant="audit"}[5m]))'
# raw sample on a master
oc adm node-logs --role=master --path=kube-apiserver/audit.log | tail -1 | python3 -m json.tool | head -40
```

## Investigation cookbook

LogQL (Loki tenant `audit`; console → Observe → Logs, or `logcli` as in `scripts/audit-query.sh`):

```logql
# who deleted / changed object X, last 24 h
{log_type="audit"} | json | objectRef_name="openshift-gitops" | verb=~"update|patch|delete"
  | line_format "{{.requestReceivedTimestamp}} {{.verb}} {{.objectRef_resource}} by {{.user_username}} imp={{.impersonatedUser_username}} rc={{.responseStatus_code}}"

# everything user Y wrote today (excluding reads)
{log_type="audit"} | json | user_username="alice@example.com" | verb!~"get|list|watch"

# every denied deletion of a critical object
{log_type="audit"} | json | verb="delete" | annotations_validation_policy_admission_k8s_io_validation_failure=~".*guardrails-critical-delete.*"

# the full approval trail of one object (request, each approval, the delete)
{log_type="audit"} | json | objectRef_name="victim" | annotations_guardrails_critical_delete_decision=~".+"
  | line_format "{{.requestReceivedTimestamp}} {{.verb}} {{.user_username}} :: {{.annotations_guardrails_critical_delete_decision}}"

# what did the request body look like (needs WriteRequestBodies)
{log_type="audit"} | json | objectRef_name="victim" | verb="patch" | line_format "{{.requestObject}}"

# impersonation, kubeadmin, break-glass
{log_type="audit"} | json | impersonatedUser_username=~".+" or user_username=~"kube:admin|system:admin|system:serviceaccount:guardrails-system:breakglass"
```

Splunk SPL equivalents:

```spl
index=openshift_audit objectRef.name="openshift-gitops" verb IN (update,patch,delete)
| table _time verb objectRef.resource user.username impersonatedUser.username responseStatus.code "annotations.guardrails-critical-delete/decision"

index=openshift_audit verb=delete "annotations.validation.policy.admission.k8s.io/validation_failure"="*guardrails-critical-delete*"
| stats count by user.username objectRef.resource objectRef.namespace objectRef.name
```

Retention and legal hold: the SIEM index is the record. Configure a 1-year hot / 7-year cold policy (or your regulator's), WORM on cold, and a documented legal-hold procedure. Loki's 90 days are operational only.
