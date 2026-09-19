# 07 · Backup and recovery

## Why (even with the guardrails)

The guardrails reduce the probability of an accidental or malicious deletion; they cannot make it zero (docs/01 residual risks R1–R3), and they do nothing for node loss, storage loss or a region outage. Recovery has three independent sources, used in this order:

1. **Git** – every Argo CD `Application`, `AppProject`, the `ArgoCD` CR patch and the guardrails themselves. Cold start = reinstall operator + apply `manifests/overlays/<phase>` + bootstrap the `guardrails` app. RPO = last merged commit.
2. **OADP (Velero)** – 6-hourly backup of `openshift-gitops`, `openshift-gitops-operator`, `guardrails-system` incl. cluster-scoped dependants; daily backup of the cluster-scoped guardrail objects; 30/90-day retention in an object-locked bucket that is *not* the Loki bucket. Captures what Git does not: repo/cluster credential secrets, Argo CD-side state (notifications, SSO config written by the operator), OLM install state.
3. **etcd snapshots** – standard OpenShift procedure (`/usr/local/bin/cluster-backup.sh`), scheduled nightly via a CronJob on a control-plane node, for whole-control-plane disasters only.

## Objectives

| Object | RPO | RTO | Path |
|---|---|---|---|
| Argo CD instance + all Applications | 6 h (OADP) / last commit (Git) | 30 min | docs/09 "Restore Argo CD" |
| A single deleted critical object (e.g. one Application) | last commit | 5 min | re-sync from Git or `velero restore --include-resources` |
| Guardrail objects | last commit | 3 min (Argo CD self-heal) / 5 min manual | `oc apply -k manifests/overlays/<phase>` |
| Audit evidence | 0 (streamed) | n/a | SIEM |

## Manifests (`manifests/06-backup`)

- `oadp-dpa.yaml` – namespace, OperatorGroup, Subscription (`redhat-oadp-operator`, channel `stable`), `DataProtectionApplication` with `openshift, aws, csi` plugins, node agent (kopia), one BSL. Replace bucket/region; for ODF/MinIO add `s3Url` + `s3ForcePathStyle`.
- `schedule-gitops.yaml` – `gitops-6h` (namespaces, `includeClusterResources: true`, TTL 30 d) and `guardrails-daily` (cluster-scoped kinds selected by the critical label, TTL 90 d).

All of them are critical: a deletion needs approvals, and `AuditForwarderChanged`-style detection applies via `GuardrailPolicyModified`/name-based rules.

Bucket policy: versioning on, Object Lock compliance mode ≥ retention, a dedicated IAM user with `PutObject/GetObject/ListBucket` and **no** `DeleteObject`; Velero expiry then fails harmlessly until lock expiry, which is what you want.

## Restore drill (quarterly, recorded in docs/12)

```bash
# 1. pick the latest completed backup
oc -n openshift-adp get backup -l velero.io/schedule-name=gitops-6h --sort-by=.metadata.creationTimestamp | tail -3
# 2. restore into a scratch namespace mapping to prove the artefact is usable (no impact on prod)
cat <<EOF2 | oc apply -f -
apiVersion: velero.io/v1
kind: Restore
metadata: { name: drill-$(date +%Y%m%d), namespace: openshift-adp }
spec:
  backupName: <backup>
  namespaceMapping: { openshift-gitops: gitops-drill }
  includedNamespaces: [openshift-gitops]
  excludedResources: [argocds.argoproj.io]      # do not start a second Argo CD instance
  restorePVs: false
EOF2
oc -n openshift-adp get restore drill-$(date +%Y%m%d) -o jsonpath='{.status.phase} {.status.errors} {.status.warnings}'; echo
oc get application,appproject,secret -n gitops-drill | head
oc delete ns gitops-drill
```

Record: backup name, restore phase, object counts, duration, who ran it.

## Real recovery of Argo CD (summary; full steps in docs/09)

1. Declare the incident; confirm via audit who/what/when (`scripts/audit-query.sh openshift-gitops`).
2. If only the `ArgoCD` CR / Applications are gone and the operator is present: `oc apply --server-side -k manifests/overlays/<phase>` restores the CR patch, AppProject and the `guardrails` Application; Argo CD then re-syncs every other app-of-apps from Git. ~10 min.
3. If the namespace/operator is gone: reinstall the operator Subscription (from your cluster-config repo), wait for the default instance, then step 2. ~30 min.
4. Repo/cluster credentials: `velero restore create --from-backup <gitops-6h-…> --include-namespaces openshift-gitops --include-resources secrets --selector argocd.argoproj.io/secret-type` or re-inject from the vault/ESO.
5. Verify with `scripts/verify-install.sh`, close the incident with the post-mortem template in docs/09.

## Verification

```bash
oc -n openshift-adp get dpa gitops-dpa -o jsonpath='{.status.conditions[?(@.type=="Reconciled")].status}'; echo
oc -n openshift-adp get backupstoragelocation -o custom-columns=NAME:.metadata.name,PHASE:.status.phase,LAST:.status.lastValidationTime
oc -n openshift-adp get schedule
oc -n openshift-adp get backup --sort-by=.metadata.creationTimestamp -o custom-columns=NAME:.metadata.name,PHASE:.status.phase,ITEMS:.status.progress.itemsBackedUp,EXPIRES:.status.expiration | tail -5
```
