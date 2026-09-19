# 16 · Production readiness review: findings, fixes and test traceability

**Method.** Two independent reviewers with no prior context audited the repository on 2026-09-18/19: one the manifests and CEL (16 tool passes, 27 findings), one the scripts, tests, CI and every document against the manifests (26 passes, 32 findings). The author then triaged all 59, fixed every Critical/High/Medium item and the Low items that were cheap, and recorded the rest as accepted with a reason. In parallel the platform owner changed the trust model (§1). Everything below reflects the repository as it is now.

**Verdict.** The central mechanism (on-object approvals validated by a built-in `ValidatingAdmissionPolicy`) survived both audits unchanged: the CEL was found sound. The defects were in the surrounding RBAC, Argo CD wiring, alert logic, shell tooling and documentation accuracy. With the fixes in this review applied, the design is production-grade *as defined in §5*; two items still require observation on your own cluster (R3, R6 in `docs/01`).

## 1. Trust-model decision (platform owner, 2026-09-19)

| Path | Approval | Cluster-side rule |
|---|---|---|
| **GitOps**: a commit merged under the repository ruleset (2 reviewers, code owners, CI invariants, signed) and applied by the Argo CD application-controller or ApplicationSet controller | in Git | none; identities in `GuardrailConfig.spec.gitopsControllers` are exempt; deletions alerted as `GitOpsCriticalDeletionApplied` for PR correlation |
| **Out of band**: `oc`, console, Argo CD UI/CLI (`argocd-server`), other controllers, humans, cluster-admin | request + 2 approvers + executor on the cluster | `guardrails-critical-delete` (V1–V4), `guardrails-critical-label-control`, `guardrails-gitops-only-mutation` (+ `-hardened`) |

Consequences implemented: `gitopsControllers` added to the CRD and the three policies; the guardrails Application prunes (`prune: true`); `CriticalResourceDeleted` fires only for out-of-band deletions; new alert `GitOpsCriticalDeletionApplied`; CI refuses `argocd-server` or any human in `gitopsControllers`; all documents, the skills and the study guide were rewritten accordingly. New residual risk R7 (repository/controller-token compromise) added to `docs/01` with its compensating controls.

## 2. Findings and resolutions

Severity as assessed by the reviewers. **Fixed** = implemented in this repository; **Accepted** = deliberately not changed, reason given.

### Critical

| # | Finding | Resolution |
|---|---|---|
| C1 | `guardrails-approver` ClusterRole granted cluster-wide `get/list/patch` on Secrets, ConfigMaps, Namespaces, ServiceAccounts, CronJobs, CSVs, Subscriptions, CRDs, Groups, policies and cluster RBAC to approvers **and** requesters: read every Secret, patch the reaper CronJob to run as break-glass, add yourself to `platform-admins`. `guardrails-executor` could delete any non-critical Namespace/Secret cluster-wide. | **Fixed.** `02-rbac/clusterroles.yaml` rewritten: cluster-scoped kinds only via `resourceNames`; namespaced kinds via `rolebindings.yaml` in the platform namespaces; **Tier B** (Namespaces, CRDs, OLM objects, Secrets, ServiceAccounts) removed from every human role (Git or break-glass only). Tests: automated §2, manual T2.2. |
| C2 | Phase 3 did not deliver the headline claim: a cluster-admin could `oc patch vapb … validationActions=[Audit]` or add themselves to `exemptUsers`, then delete, because the GitOps-only policy was Audit until phase 4 and V2–V4 only constrain annotation writes. | **Fixed.** New binding `guardrails-gitops-only-mutation-hardened`, `[Deny, Audit]` in **every** phase, scoped to the self-protection set (GuardrailConfig, policies/bindings, `guardrails-*` RBAC, privileged Groups, APIServer/OAuth, labelled CronJobs). Approval annotations still allowed. Tests: automated §4, manual T3.7/T3.8/T8.1. |
| C3 | `patch groups` let any approver add themselves to `platform-admins` (Groups have no RBAC escalation check and were not in the GitOps-only policy). | **Fixed.** Groups added to the GitOps-only policy with `users` compared; covered by the hardened binding; the group-sync SA is the documented trusted writer. Test: automated §4. |
| C4 | Argo CD `role:operator` allowed `applications, override` (`sync --local` any manifest as the controller) and create/update in the `guardrails` project (point it at any branch) and full ApplicationSet rights. | **Fixed.** `override` denied; create/update in `guardrails/*` denied; ApplicationSet create/update denied. Test: manual §5 `argocd account can-i`. |

### High

| # | Finding | Resolution |
|---|---|---|
| H1 | The `guardrails` Application could not sync: AppProject destinations lacked `openshift-operators-redhat`, `openshift-etcd-backup`, `openshift-kube-apiserver` and the whitelist lacked `OAuth`. Self-heal of the control was dead. | **Fixed** (destinations + whitelist + `openshift-monitoring`). `verify-install.sh` now asserts Synced/Healthy. Test: manual D2. |
| H2 | `resourceExclusions: guardrails.example.com/*` hid `GuardrailConfig` from Argo CD itself (PR changes never applied). | **Fixed** (exclusion removed; fencing stays via AppProject whitelists). |
| H3 | `parameterNotFoundAction: Deny` on the broad named binding = cluster-wide outage for OLM/namespaces/RBAC if `GuardrailConfig` were missing. | **Fixed** (named binding `Allow`; labelled binding stays `Deny`; absence alerted). |
| H4 | Reaper SA over-privileged (read all Secrets, patch Groups/VAPs/RBAC) and a *trusted writer* in the GitOps-only policy: any pod in `guardrails-system` could edit every critical object. | **Fixed.** Reaper ClusterRole trimmed to Tier-A annotation targets; removed from `isTrustedWriter` (its annotation-only change passes on its own). NetworkPolicy default-deny added to `guardrails-system`. |
| H5 | OLM's deletion of a superseded CSV in `openshift-gitops-operator` was denied → GitOps operator upgrades would wedge. | **Fixed** (`olmServiceAccounts` V1 clause). |
| H6 | `GuardrailPolicyModified` paged every 10 min on `cronjobs/status` and VAP status writes. | **Fixed** (`objectRef_subresource=""`, kube-system and trusted identities excluded, in all integrity rules). |
| H7 | Minting tokens for exempt/trusted SAs was unalerted; impersonating them was the undocumented one-command bypass. | **Fixed.** New alerts `PrivilegedTokenMinted`, `PrivilegedIdentityImpersonated`; `ControlPlaneNodeAccess` extended to the GitOps namespaces; break-glass mint restricted to the `breakglass-custodians` Role; R1 rewritten. Tests: manual T7.4, T13. |
| H8 | Test setup labelled scratch objects as cluster-admin → denied by label control in phase 3; the whole matrix was invalid. | **Fixed** (approver labels; phase-aware expectations). |
| H9 | Test cleanup left the namespace Terminating forever and broke the next run. | **Fixed** (cleanup runs the full workflow on each remaining critical object; aborts if the namespace is Terminating). |
| H10 | go-template `index` on a missing key printed `<no value>`, breaking every script's state logic. | **Fixed** (`{{with index . "k"}}{{.}}{{end}}` everywhere). |
| H11 | Scripts failed on bash 3.2 (macOS) for cluster-scoped targets (`"${NSARGS[@]}"` with `set -u`). | **Fixed** (`${NSARGS[@]+"${NSARGS[@]}"}`), verified on bash 3.2.57. |
| H12 | Reaper aborted at the first kind whose CRD was absent (`pipefail`). | **Fixed** (`|| true`, complete resource list, `--resource-version` to avoid clobbering a concurrent approval). |
| H13 | CI red on the first PR (shellcheck exit on style findings; `if: env.X` never true for the pre-prod dry-run; grep invariants matched comments and could be slipped). | **Fixed** (`--severity=warning`; job-level `HAS_PREPROD`; invariants rewritten in Python over parsed YAML, incl. `argocd-server ∉ gitopsControllers`). |

### Medium

| # | Finding | Resolution |
|---|---|---|
| M1 | `payloadUnchanged` ignored `aggregationRule`, `binaryData`, `immutable`, Application `operation`, `metadata.finalizers`, `metadata.ownerReferences`; GitOps-only policy did not cover Groups, Roles, CronJobs, ServiceAccounts, AlertmanagerConfigs, NetworkPolicies. | **Fixed** in both policies. |
| M2 | Delete alerts missed `deletecollection`; `GitOpsResourceDeleted` paged on ApplicationSet prunes and OLM CSV replacement. | **Fixed** (`delete|deletecollection`; identities excluded). |
| M3 | Phases 1–2 had no "would have been denied" signal. | **Fixed** (`CriticalDeleteWouldBeDenied`). |
| M4 | `CriticalDeletionApprovalRecorded` did not fire on the request itself. | **Fixed** (matches request or approvals in the body). |
| M5 | Namespaced `guardrails-*` Roles/RoleBindings not name-protected. | **Fixed** (named binding covers `roles`, `rolebindings`). |
| M6 | Audit-pipeline dependencies (`openshift-operators-redhat`) not critical; Splunk CA referenced unconditionally (CLF Degraded if absent). | **Fixed** (namespace labelled; CA block optional). |
| M7 | `AuditLogIngestionStalled` timing documented as 12 min, actual ~20. | **Fixed** (docs and test guide). |
| M8 | `oc auth can-i --as` raised `ImpersonationUsed`. | **Fixed** (access reviews excluded). |
| M9 | Runbook token revocation used `useroauthaccesstokens` (own tokens only) and claimed SA tokens can be rotated. | **Fixed** (correct command; bound-token limits stated). |
| M10 | CI invariant 3 (`exemptUsers`) bypassable; kubeconform could pass vacuously. | **Fixed** (parsed-YAML invariants; schema version `master`). |
| M11 | Auditors could not read the Loki audit tenant. | **Fixed** (`cluster-logging-audit-view` binding). |
| M12 | Docs disagreed on counts, trusted mutators, "approvals are wiped" (V4 denies unless cleared), RBAC claims. | **Fixed** across docs, AGENTS.md, context, skills, study guide. |
| M13 | `execute-deletion.sh` would hang on namespaces; Tier-B kinds not guarded. | **Fixed** (`--wait=false`; Tier-B refusal). |
| M14 | Test matrix cases passing for RBAC reasons instead of policy; reaper cases vacuous; sign-off mode still impersonated. | **Fixed** (explicit executor-role case, reaper via Job, SA cases skipped in sign-off mode). |
| M15 | `verify-install.sh` miscounted approvers, relied on an undocumented `Ready` condition, missed new policies. | **Fixed.** |
| M16 | etcd snapshots unencrypted while etcd encryption was only an example; CronJob used `hostNetwork`. | **Fixed** (`APIServer.spec.encryption.type: aesgcm` in base; `hostNetwork` removed). |

### Low and accepted

| # | Finding | Resolution |
|---|---|---|
| L1 | Info route lacked `continue`; inhibit rule 1 was a no-op. | **Fixed.** |
| L2 | `controller.diff.server.side` in `extraConfig` is a no-op. | **Fixed** (`spec.controller.env`). |
| L3 | Images by tag, not digest. | **Accepted**: digests differ per mirror; documented in `docs/00` as a placeholder to pin during A4. |
| L4 | MachineConfig `sshAuthorizedKeys: []` does not remove installer keys (MCO merges). | **Fixed in text**: masking `sshd` is the effective control; the installer MachineConfig must be edited in the same PR. |
| L5 | `includeClusterResources: true` backed up all cluster-scoped objects 6-hourly. | **Fixed** (omitted → related only). |
| L6 | `runbookURL` and every `runbook_url` are dead until placeholders are replaced. | **Accepted**: covered by the placeholder sweep (now also covers README, CLAUDE.md, llms.txt, html, .cursor). |
| L7 | `oc delete project --dry-run` propagation not guaranteed. | **Fixed in text** (phase-3-only note). |
| L8 | Owners are all "platform-engineering". | **Accepted**: organisation-specific; fill in A2. |
| L9 | `.claude/settings.json` denies `oc --as=` only as a prefix. | **Accepted**: defence in depth only; the alert is the control. |

### Deletion-lifecycle review (2026-09-19, docs/19)

Tracing one request through prevention, notification, counting and expiry found two compile-level defects that the earlier reviews and CI had missed, and six functional gaps. Full detail: docs/19 §9.

| # | Finding | Resolution |
|---|---|---|
| D1 | **Critical.** `isOlmCsvReplacement` (vap-critical-delete) ended with a stray `"` inside a `>-` block: the CEL did not compile, so OLM could not replace the GitOps-operator CSV in phase 3. | **Fixed.** CI now checks every CEL literal and bracket (verified to fail on the old file). |
| D2 | **Critical.** `isTrustedWriter` (vap-gitops-only-mutation) had the same defect: the always-Deny `-hardened` binding would have denied Argo CD's own updates to the policies and GuardrailConfig (no self-heal, no GitOps change to the guardrail). | **Fixed**, same CI check. |
| G1 | Approvers were never notified directly (only an info alert to the platform channel, without counts). | **Fixed.** `guardrails-deletion-tracker` (records state, never denies) + Loki rules `CriticalDeletionRequested/Approved/ApprovalsExpired/RequestClosed` + route `audience="approvers"` → receiver `guardrail-approvers` (approvers' list + Teams channel). |
| G2 | No view of "have / need / remaining". | **Fixed.** Tracker fields in every notification; `scripts/status-deletion.sh`, `scripts/list-pending-deletions.sh`; `show_state` marks expired, future-dated and invalid entries. |
| G3 | Requests never expired and carried no time. | **Fixed.** `delete-requested-at` (required by V4, part of the request integrity), `requestTTL` 24 h, reaper withdraws stale/undated/future-dated requests with their approvals. |
| G4 | No reminders for stuck requests. | **Fixed.** `CriticalDeletionPendingApproval`, `CriticalDeletionAwaitingExecution` (hourly). |
| G5 | A stopped/suspended/missing reaper was not alerted. | **Fixed.** `GuardrailReaperNotRunning`. |
| G6 | Concurrent approvals produced a confusing V3 denial. | **Fixed.** `approve-deletion.sh` writes with `--resource-version`. |
| G8 | The reaper's GNU `date -d` accepted `""`, `now`, `yesterday` as timestamps (an `x\|now` approval would never expire). | **Fixed.** Strict RFC3339 check before parsing (reaper, `lib.sh`). |
| G7 | CI did not check CEL syntax, tracker parity or TTL windows. | **Fixed.** Four new invariants in `policy-ci.yaml`. |

## 3. Test traceability matrix

Every control has at least one automated case (A = section/case in `scripts/test-guardrails.sh`, which is phase-aware) or a manual case (M = T-number in `docs/14`), and the alert that proves detection. "verify" = `scripts/verify-install.sh`. Nothing is uncovered.

| Control | A | M | Alert / evidence |
|---|---|---|---|
| **V1** out-of-band delete without approvals (cluster-admin) | §3 | T3.1 | CriticalResourceDeleteDenied / CriticalDeleteWouldBeDenied |
| V1 delete by selector (deletecollection) | §3 | T3.3 | same |
| V1 name-protected: ArgoCD CR, namespace, CRD, GuardrailConfig, binding (R3), group, `guardrails-*` CRB, Subscription, CLF, Application | §3 (dry-run) | T3.4–T3.9 | same |
| V1 with 1 approval | §6 | T4.11 | same |
| V1 executor ∈ approvers (policy, not RBAC) | §6 `approver1-executor` | T4.15 | same |
| V1 happy path → deleted | §6 | T5.1, T5.2 | **CriticalResourceDeleted** (email + Teams, timing T9.2) |
| V1 after cancel | §7 | T6.1 | denied |
| V1 OLM CSV replacement allowed | – | operator upgrade on pre-prod (Part B2 re-run) | no CriticalResourceDeleteDenied for OLM SA |
| V1 GitOps path exempt (controller prune) | §9 (impersonation) | T7.1 | **GitOpsCriticalDeletionApplied** |
| V1 Argo CD UI/CLI (`argocd-server`) not exempt | §9 | T7.3 | CriticalResourceDeleteDenied |
| V1 break-glass exempt | – | T13 | BreakGlassUsed, decision `exempt=true` |
| **V2** label removal denied | §3 | T3.2 | denied |
| **V3** forged (admin writes 2), wrong name, own request, before request, malformed, smuggled data, duplicate, list replaced | §5, §6 | T4.1, T4.4, T4.6–T4.9, T4.12, T4.13 | denied |
| V3 valid approvals append | §6 | T4.10, T4.14 | CriticalDeletionApprovalRecorded, CriticalDeletionApproved |
| **V4** request needs a valid `delete-requested-at`; refreshing it with approvals present is denied | §5, §6 | T4.17, T4.18 | denied |
| Request lifetime: reaper withdraws a request older than `requestTTL` | §8 | T6.3 | CriticalDeletionRequestClosed (request-expired) |
| Approval progress visible (have / need / remaining, expiries) | – | T6.4 | status-deletion.sh, list-pending-deletions.sh |
| Approvers notified: request, each approval, expiry, closure, reminders | – | T6.5 | CriticalDeletion{Requested,Approved,ApprovalsExpired,RequestClosed,PendingApproval,AwaitingExecution} |
| Reaper not running / suspended / missing | verify (CronJob present) | suspend the CronJob on pre-prod for 40 min | GuardrailReaperNotRunning |
| CEL compiles (no unterminated literal or unbalanced bracket), tracker parity, TTL windows | CI | – | policy-ci invariants |
| V3 reaper remove-only; cannot add | §8 | T6.2 | GuardrailReaperFailing (negative) |
| **V4** request by someone else's name; developer outside groups; reason edited after approvals; cancel by third party | §5, §6, §7 | T4.2, T4.3, T4.16, T6.1 | denied / allowed |
| **Label control** UPDATE by requester/admin denied, approver allowed; CREATE with label denied | §1 | T3.10 | denied |
| **GitOps-only (phase 4)** human spec edit denied; trusted identities allowed | §4 (phase-aware) | T2.3 | ArgoCDDirectMutation (phases 1–3) |
| **Hardened binding (every phase)** validationActions, exemptUsers, Group.users, reaper CronJob SA; annotations still allowed | §4 | T3.7, T3.8, T8.1 | GuardrailPolicyModified |
| **RBAC least privilege** approver cannot read/list Secrets, cannot delete; requester cannot delete namespaces (Tier B) | §2 | T2.2 | RBAC Forbidden |
| RBAC-escalation policy warns + stamps | §10 | T14 | PrivilegedRBACChange |
| Reaper TTL expiry and future-dated entries | §8 | T6.2 | job log |
| Phase-1 annotation / phase-2 warning | phase-aware run | T1.1 / T15 | CriticalDeleteWouldBeDenied |
| Self-heal after break-glass edit | – | T8.1 | GuardrailPolicyModified + BreakGlassUsed |
| Impersonation of approver / of exempt identity / token mint | §9 side-effect | T12, T7.4, T13 | ImpersonationUsed, PrivilegedIdentityImpersonated, PrivilegedTokenMinted |
| **Impersonation dry-run only** (write denied, dry-run allowed, access review allowed, impersonated approver/break-glass not honoured, userextras unforgeable) | §10 | T12b | ImpersonatedWriteDenied |
| Humans and break-glass hold `guardrails-platform-admin`, not `cluster-admin`; no custom role grants impersonate on userextras | verify | docs/17 §Verification | – |
| kubeadmin / system:admin write | – | B1 (kubeadmin removed; verify) | KubeadminOrSystemAdminUsed |
| Control-plane exec / debug | – | `oc debug node` on pre-prod once | ControlPlaneNodeAccess |
| Audit profile / forwarder / rules change out of band | – | T3.8, T10.1 | AuditProfileChanged, AuditForwarderChanged |
| Argo CD credential Secret deleted | – | break-glass delete of a scratch Secret in openshift-gitops (pre-prod) | ArgoCDCredentialSecretDeleted |
| Argo CD availability (controller/server/apps/operator missing, namespace Terminating, guardrails app OutOfSync) | verify (Synced/Healthy) | docs/11 §Alert delivery item 4; §17 cleanup shows Terminating | ArgoCD*Missing, GitOpsNamespaceTerminating, GuardrailApplicationOutOfSyncOrMissing |
| Detection pipeline health (ingestion stalled, forwarder, ruler, reaper, VAP errors/absent/slow, notification failures, AM config) | verify (rules present) | T10.1; synthetic `amtool` T9.1; rotate the Teams URL to a bad value on pre-prod for `GuardrailNotificationFailing` | respective alerts |
| Synthetic delivery, repeat interval, inhibition | – | T9.1, T9.3 | Teams + email |
| Argo CD hardening: no finalizer, prune, selfHeal, disableAdmin, RBAC deny delete/override, AppProject fencing | verify + CI invariants | T7.2, docs/05 `argocd account can-i` | – |
| Git side: ruleset, CI invariants (Deny present, no human/argocd-server in exempt lists, finalizer, secrets) | CI | T11.1, T11.2 | – |
| Backup schedule / restore drill | verify (last backup) | T16 | – |
| Identity: kubeadmin removed, no User on cluster-admin, ≥ 4 approvers, break-glass custodians | verify | B1 | – |
| Test re-runnability (namespace not left Terminating) | §11 | §17 | – |

## 4. What "production-grade" means here, and what remains

Met: least-privilege RBAC with explicit tiers; fail-closed enforcement in kube-apiserver with self-protection from phase 1; independent detection pipelines with health alerts on the alerting itself; reproducible, phase-aware tests with retained evidence; documented and rehearsed break-glass; backups with encryption at rest; Git as the single source of truth under a no-bypass ruleset; every claim in the documents traceable to a manifest and a test.

Still to observe on your cluster (cannot be proven locally): R3 (does VAP evaluate deletes of its own bindings on your build), R6 (Loki field names after Logging upgrades), the CEL compile on the API server (first `--dry-run=server` in Part C1), and the real latency of alert delivery (T9.2).

Accepted residual risks: R1 is now closed for human roles by docs/17 (impersonation restricted to reads, access reviews and dry-runs; only the vaulted `system:masters` certificate can still forge identities), R2 (node/etcd access: SSH lockdown example, encryption, exec alert), R7 (repository or controller-token compromise: ruleset, PR correlation of every Git-driven deletion, token-mint alert), R8 (Tier-B kinds need break-glass out of band: deliberate).
