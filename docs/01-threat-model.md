# 01 · Threat model and residual risk

## Assets

| Asset | Why it is critical | Failure impact |
|---|---|---|
| OpenShift GitOps: `ArgoCD/openshift-gitops`, namespace, operator Subscription/CSV, `argoproj.io` CRDs, AppProjects, Applications, repo/cluster secrets | Single control loop for every workload; deleting the CRDs cascades to every Application; deleting an Application with the cascade finalizer deletes the workloads it manages | Platform-wide outage or silent config drift; hours to rebuild |
| The guardrail objects themselves (`ValidatingAdmissionPolicy`/Binding, `GuardrailConfig`, `guardrails-*` RBAC, approver groups, reaper) | If they go, everything else is one `oc delete` away | Loss of the control |
| Audit pipeline (`APIServer/cluster` audit profile, `ClusterLogForwarder`, `LokiStack`, `AlertingRule`s, `alertmanager-main`) | Detection and forensics | Blind spot; unattributable actions |
| Backups (`DataProtectionApplication`, `Schedule`s, bucket) | Last line of recovery | Unrecoverable data loss |
| Privileged identities (`cluster-admin` bindings, `platform-admins`, break-glass SA, `system:admin` kubeconfig, `kubeadmin`) | Whoever holds them can do anything RBAC allows | Complete compromise |

## Actors and scenarios

| # | Scenario | Likelihood | Control(s) |
|---|---|---|---|
| S1 | Admin runs `oc delete ns openshift-gitops` / `oc delete argocd ...` by mistake (wrong context, wrong tab) | high | VAP denies (L3); alert `CriticalResourceDeleteDenied` (L6) |
| S2 | Admin deletes an Argo CD `Application` that still carries `resources-finalizer` → cascade deletes workloads | high | Finalizer removed / `preserveResourcesOnDeletion` (L2); Application labelled critical → VAP (L3) |
| S3 | A PR removes a critical manifest from Git and Argo CD prunes it | medium | **This is the approved GitOps path**: the 2-reviewer ruleset with code owners (L8) is the control; the deletion is applied by the exempt controller and alerted as `GitOpsCriticalDeletionApplied` for PR correlation (L6); CI invariants reject weakening PRs |
| S4 | Compromised or malicious cluster-admin tries to delete / cripple Argo CD | low, high impact | VAP applies to `system:masters` (L3); forging approvals or impersonating the exempt Argo CD controller / break-glass → `ImpersonationUsed` / `PrivilegedIdentityImpersonated` P1, minting their tokens → `PrivilegedTokenMinted` P1 (L6); no standing cluster-admin for humans (L1) |
| S5 | Attacker first disables the guardrail (delete binding, edit `GuardrailConfig`, set `validationActions: []`) | low | Self-protection set is GitOps-only in **every phase** (`-hardened` binding, L3+L4); RBAC scoped with `resourceNames`, no human may patch these beyond annotations (L1); Argo CD self-heal (L2); `GuardrailPolicyModified` P1 (L6) |
| S6 | Attacker blinds detection first (downgrade audit profile, delete forwarder, edit Alertmanager) | low | All are critical (L3); `AuditProfileChanged`, `AuditForwarderChanged` (L6); metrics-based `AuditLogIngestionStalled`, `ArgoCD*Missing` fire from a **separate** pipeline (L6) |
| S7 | Operator / controller bug deletes objects (GC after parent deletion, namespace controller, OLM uninstall) | medium | Controllers are not exempt: their deletes are denied, they retry, an alert fires; parents (namespace, CSV, CRD) are also protected so cascades cannot start |
| S8 | Approver collusion (two approvers + executor conspire) | very low | Out of scope for a technical control; approvals and executor are three distinct, audited humans; membership recertified quarterly (docs/12) |
| S9 | Node/etcd level access (`oc debug node`, SSH to control plane, `etcdctl`) bypasses admission entirely | low | Residual. `ControlPlaneNodeAccess` alert; no SSH keys on control plane (MachineConfig); etcd encryption; bastion + session recording |
| S10 | Loss of the whole cluster / region | low | OADP to a different, object-locked bucket; Git is the source of truth; cold-start runbook |

## Layered controls

| Layer | Control | Prevents / detects |
|---|---|---|
| L1 | Identity: IdP groups, JIT cluster-admin, no `kubeadmin`, vaulted `system:admin` kubeconfig, dual-control break-glass | S4, S8 |
| L2 | Argo CD native: no cascade finalizers, `selfHeal`, AppProject fencing, Argo CD RBAC (operators cannot delete/override apps or touch the guardrails project) | S2, S5 |
| L3 | Admission: `guardrails-critical-delete` (two-person rule for out-of-band deletes), `guardrails-critical-label-control`, `guardrails-gitops-only-mutation` (+ `-hardened`), `guardrails-rbac-escalation-audit` | S1, S2, S4–S7 |
| L4 | Self-protection: policy objects critical, RBAC-locked, self-healed, alerted | S5 |
| L5 | Audit: `WriteRequestBodies`, forwarded to SIEM + Loki, 90 d in-cluster, WORM buckets | forensics for all |
| L6 | Detection: 20 Loki rules on the audit stream + 15 metrics rules, two independent pipelines | S1–S7, S9 |
| L7 | Notification: Alertmanager → email + Teams, no grouping delay, repeat until resolved | time-to-respond |
| L8 | Process: GitHub 2-reviewer ruleset, CODEOWNERS, signed commits, CI invariants, quarterly recertification and restore drills | S3, S8 |

## What this design deliberately does **not** do

- **It does not stop three colluding people.** A two-person rule is the industry standard for irreversible operations (nuclear, finance, PKI); the third person (executor) makes it a three-person rule. Collusion is addressed by audit, recertification and segregation of duties, not by software.
- **It does not protect against control-plane node compromise.** Anyone who can write to etcd or edit static pod manifests is outside the Kubernetes trust boundary. Keep that population at zero: no SSH keys on masters, `oc debug node` alerted and reserved for incidents, MachineConfig managed from Git.
- **It does not remove `cluster-admin`.** It makes `cluster-admin` unable to delete critical resources alone and unable to disable the guardrail unnoticed. `cluster-admin` can still impersonate an approver; that is why impersonation is a P1 alert and human `cluster-admin` is time-boxed. If your IdP cannot do JIT membership, treat `platform-admins` membership as a quarterly-recertified, two-person-approved change (the group is critical, so it is).
- **It is not a substitute for backups.** It lowers the probability of needing them.

## Residual-risk register

| ID | Risk | Owner | Compensating control | Review |
|---|---|---|---|---|
| R1 | cluster-admin impersonates an approver (forged approval), the exempt break-glass SA or an Argo CD controller (one-command bypass), or mints their tokens | Security | `ImpersonationUsed`, `PrivilegedIdentityImpersonated`, `PrivilegedTokenMinted` P1; JIT cluster-admin is a hard prerequisite; audit shows both identities so it is provable | quarterly |
| R2 | Node/etcd-level bypass | Platform | no SSH keys; `ControlPlaneNodeAccess` alert; session recording on bastion | quarterly |
| R3 | Whether a VAP may match `validatingadmissionpolicies`/`...bindings` on your exact build must be **confirmed in phase 1** (`scripts/test-guardrails.sh` case "delete policy binding"). If it cannot, deleting a binding is still RBAC-restricted to the Argo CD SA + break-glass, is self-healed by Argo CD within its sync interval, and raises `GuardrailPolicyModified` P1 | Platform | RBAC + self-heal + alert | phase 1 exit |
| R4 | Approval TTL is enforced by the reaper CronJob, not by admission (CEL has no clock). A stale approval on a specific object could be used later for **that object only** | Platform | reaper every 10 min, also drops future-dated entries; `GuardrailReaperFailing` alert; a change to the request is denied unless approvals are cleared with it | quarterly |
| R7 | The GitOps path is only as strong as the repository controls: a compromised GitHub account with two reviewers, or a compromised Argo CD controller token, can delete critical objects | Security | ruleset without bypass, signed commits, secret scanning, CI invariants; `GitOpsCriticalDeletionApplied` must always correlate with a merged PR; `PrivilegedTokenMinted`, `ControlPlaneNodeAccess` cover the controller identity; Argo CD RBAC denies override/create in the guardrails project | quarterly |
| R8 | Tier-B kinds (namespaces, CRDs, OLM objects, Secrets, ServiceAccounts) have no workflow path: an out-of-band deletion needs break-glass | Platform | deliberate: a patch on these is an escalation primitive; Git remains the normal path | annual |
| R5 | Alert delivery depends on SMTP relay and Teams Workflows availability | Platform | every guardrail alert is also routed to the default on-call receiver; Alertmanager `repeat_interval: 30m` | monthly synthetic alert |
| R6 | Loki `json` field names depend on the Logging data model; a Logging major upgrade may rename them | Platform | `AuditLogIngestionStalled` would not catch a rename; run `scripts/test-guardrails.sh` after every Logging operator upgrade | per upgrade |
