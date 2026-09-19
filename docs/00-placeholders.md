# 00 · Placeholders to replace before the first apply

Everything organisation-specific is a literal placeholder so a single search/replace prepares the repository. Run the check at the bottom until it returns nothing.

| Placeholder | Meaning | Files | Notes |
|---|---|---|---|
| `guardrails.example.com` | Label/annotation prefix and API group of `GuardrailConfig` | everywhere | Choose a DNS name you own, e.g. `guardrails.acme.io`. **Change it once, before phase 1**; it is baked into the CRD group and the CEL. |
| `example-org/openshift-administration` | GitHub org/repo of this repository | `manifests/04-argocd/*`, `docs/*`, `.github/*`, alert `runbook_url`s | |
| `@example-org/platform-engineering`, `@example-org/security` | GitHub teams for CODEOWNERS | `.github/CODEOWNERS` | each team ≥ 3 members with write access |
| `approver1@example.com` … `auditor1@example.com` | Bootstrap group members | `manifests/00-namespaces-and-groups/groups.yaml` | Prefer IdP group sync; keep group names |
| `platform-oncall@example.com`, `security-oncall@example.com`, `openshift-alerts@example.com` | Alert recipients / sender | `manifests/05-alerting/alertmanager-main.yaml` | |
| `smtp.example.com:587` + `REPLACE_FROM_VAULT` | SMTP relay and password | `alertmanager-main.yaml` | password comes from the vault, never Git |
| `https://REPLACE.logic.azure.com/...` | Teams Workflows webhook URL | `alertmanager-main.yaml` (2×) | see docs/06 §Teams |
| `prod-eu-1` | Cluster identifier label on every audit line | `manifests/01-audit/clusterlogforwarder-audit.yaml` | one per cluster |
| `https://splunk-hec.example.com:8088`, index `openshift_audit`, secret `splunk-hec` | SIEM endpoint | `clusterlogforwarder-audit.yaml` | or swap to the Elasticsearch/syslog block |
| `gp3-csi` | Storage class for LokiStack PVCs | `manifests/01-audit/lokistack.yaml` | RWO, SSD |
| `ocp-audit-loki`, `ocp-prod-eu-1-oadp`, `eu-west-1`, endpoints | Buckets/regions | `loki-s3-secret.example.yaml`, `oadp-dpa.yaml` | two different buckets, Object Lock on both |
| `stable-6.4`, `stable` | Operator channels | `manifests/01-audit/operators.yaml`, `06-backup/oadp-dpa.yaml` | verify with `oc get packagemanifest` |
| `registry.redhat.io/openshift4/ose-cli-rhel9:v4.21` | Reaper image | `manifests/03-guardrails/reaper-cronjob.yaml` | mirror it if disconnected |
| `system:serviceaccount:openshift-gitops:openshift-gitops-argocd-application-controller` | Argo CD controller identity | `guardrailconfig-default.yaml` | change if your ArgoCD CR is not named `openshift-gitops` |

```bash
# must print nothing when you are done (secrets excluded on purpose: they stay REPLACE_* until injected from the vault)
grep -RnE 'example\.com|example-org|REPLACE' manifests docs scripts .github llm .claude .cursor html AGENTS.md CLAUDE.md README.md llms.txt \
  | grep -vE 'REPLACE_FROM_VAULT|REPLACE_ME|REPLACE\.logic|sig=REPLACE|workflows/REPLACE'
```

Changing `guardrails.example.com` later means: new CRD group, re-label every critical object, update the CEL in three policies, the reaper ConfigMap, the scripts' `lib.sh`, the Loki rule field names (`annotations_guardrails_...` are derived from the **policy names**, not the prefix, so those stay). Do it once, before phase 1.
