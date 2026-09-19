# 13 · Solution justification: why this is an enterprise-grade design

This document is written for architecture review boards, security officers and auditors. It states the requirements, the real-world concerns behind them, the design decisions taken, the alternatives rejected and the evidence that each concern is closed. Every claim points to the file that implements it and to the test in `docs/14-manual-test-guide.md` that proves it.

## 1. Requirements as stated, and what they really mean

| # | Requirement (as requested) | Real-world concern behind it | Where it is met |
|---|---|---|---|
| R1 | "Any edit, deletion can be audited: what resource, deleted by whom" | Attribution that survives an incident: personal identity, exact object, exact change, tamper-evident storage, retained long enough for regulators | `manifests/01-audit/*`, docs/02 |
| R2 | "Critical resource should not be deleted by a single user even if it is the cluster admin" (out of band) | Insider error and insider threat at the highest privilege level; `cluster-admin` is `*` on `*`, RBAC cannot restrain it. Changes through Git are approved by the repository ruleset instead | `manifests/03-guardrails/vap-critical-delete.yaml`, docs/04, docs/08 |
| R3 | "Argo CD will not be deleted by a single authorised user; multiple approvers need to approve" | Argo CD is the control loop for every workload; deleting it, its namespace, CRDs or operator is the highest-impact single command on the cluster | name-protected rules in the policy, `manifests/04-argocd/*`, docs/05 |
| R4 | "Deletion must be alerted by email and Teams so the team can take instant action" | Mean-time-to-detect measured in seconds, delivery through two channels, no grouping delay, keeps paging until acknowledged | `manifests/05-alerting/*`, docs/06 |
| R5 | "Even though we have backup and restore, we need this" | Backups are recovery, not prevention; prevention plus detection reduces the number of restores and the blast radius of each | whole design; docs/07 for the recovery side |
| R6 | "If I missed anything, cover it; production grade, strong guardrail, best proven solution" | Identity hardening, self-protection of the control, safe rollout, testability, operations, compliance evidence, honest residual risk | docs/01, 03, 08, 10, 11, 12 |

## 2. Design principles applied

1. **Prevent, detect, recover, in that order, with independent mechanisms for each.** Prevention (admission policy) does not depend on detection (audit pipeline) and detection has two pipelines (audit events and metrics) that fail independently. Recovery (Git, OADP, etcd) does not depend on either.
2. **Enforce at the choke point.** Every API request, from every client and controller, passes through kube-apiserver admission. There is no second door: not the console, not the Argo CD UI, not `oc`, not a controller, not Git.
3. **No new trusted component.** The control is a built-in API-server feature (`ValidatingAdmissionPolicy`, GA since Kubernetes 1.30, shipped in OpenShift 4.21 as Kubernetes 1.34). There is no webhook whose pod can be deleted, no operator whose CSV can be removed, no CRD whose deletion would silently switch the control off.
4. **Separation of duties by construction.** Requester, approver 1, approver 2 and executor are four roles held by at least three people. The identity of each is written by the API server from the authenticated session, not typed by a human.
5. **Defence in depth against disabling the control.** The control protects itself (name-protected), is RBAC-locked, self-healed by Argo CD, alerted on any write, and changeable only through a two-reviewer PR.
6. **Fail closed, roll out open.** The policy is `failurePolicy: Fail` / `parameterNotFoundAction: Deny`, but it is introduced in audit-only mode and promoted through warn to deny with explicit exit criteria.
7. **Everything is code, everything is tested.** Manifests, policies, alert rules, scripts, CI invariants and a phase-aware test matrix are in one repository under a ruleset with no bypass.
8. **Honesty about limits.** What the design cannot do (collusion of three people, node/etcd-level access) is written down in a residual-risk register with compensating controls, not hidden.

## 3. Concern-by-concern justification

### 3.1 "Who did what?" must be answerable for every change

**Concern.** After an incident the questions are: which identity, which object, what was the change, when, from where, and was it authorised. Kubernetes' default audit policy (metadata only) answers only half of that, logs are lost when a control-plane node is replaced, and an attacker with cluster-admin can delete local logs.

**Decision.** `APIServer/cluster` audit profile `WriteRequestBodies` with explicit `customRules` for humans and the GitOps identities; OpenShift Logging 6 `ClusterLogForwarder` ships all audit sources (`kubeAPI`, `openshiftAPI`, `auditd`, `ovn`) to **two** destinations from one pipeline: the SIEM (system of record, WORM retention) and LokiStack (90-day operational store for alerting); the policy stamps a decision annotation on every evaluated request so approvals, approvers, exemptions and denials are part of the event itself.

**Why not the alternatives.** `Default` profile: no bodies, cannot reconstruct an edit. `AllRequestBodies`: multiplies volume and writes secret values into logs on every `GET`. SIEM only: an SIEM outage or misrouting blinds alerting. Loki only: 90 days is not a compliance retention.

**Evidence.** docs/02 cookbook; tests T2.x in docs/14 show the annotation on allowed and denied requests; `AuditProfileChanged`, `AuditForwarderChanged`, `AuditLogIngestionStalled` alerts prove tampering with the pipeline is itself detected.

### 3.2 A single person, even cluster-admin, must not be able to delete a critical resource

**Concern.** Human error (wrong context, wrong namespace, copy-paste), compromised admin credentials, or a malicious insider. RBAC cannot help: `cluster-admin` is authorised for everything, and any custom role that includes `delete` allows unilateral deletion.

**Decision.** A CEL policy in the admission chain. Authorisation (RBAC) answers "may this identity delete this kind"; admission answers "is this specific deletion approved". Admission applies to `system:masters` too; the only identities that skip it are configured explicitly (`exemptUsers`: the API-server loopback and a dual-control break-glass service account).

**The two-person rule, precisely.** A DELETE is allowed only if the object carries (a) a request with a reason, (b) the requester's identity as recorded by the API server, (c) at least `minApprovers` (2) distinct approval entries, each of which could only have been appended by the person it names while a member of the approver group, none of whom is the requester, and (d) the executor is not one of the approvers. Because (b) and (c) are validated at write time against `request.userInfo`, an approval cannot be typed in by someone else. Because approvals are wiped whenever the request text or author changes, an approval always refers to the justification the approvers saw.

**Why not the alternatives.** Kyverno/Gatekeeper: capable, but they add a webhook whose availability, RBAC and CRDs become part of the attack surface (delete the `ValidatingWebhookConfiguration` and the control is gone) and a second operator to patch. A separate "approval" CRD instance per deletion: VAP evaluates a request against *all* parameter objects matching a selector, which makes "any matching ticket" semantics unreliable, and CEL has no clock to expire tickets; approvals on the target object are simpler, self-cleaning and produce the audit trail on the object itself. Finalizers: do not block the DELETE, only delay it, and can be patched away. Argo CD sync windows or `Prune=false` alone: only cover the Git path.

**Evidence.** docs/04 rule table; docs/14 tests T3.1–T3.9 (denials for cluster-admin), T4.1–T4.13 (forged approvals), T5 (happy path).

### 3.3 Argo CD specifically must survive a single authorised user

**Concern.** Argo CD has three deletion paths: delete the instance (CR, namespace, operator, CRDs), delete *through* it (Application with cascade finalizer, ApplicationSet), or delete *via Git* (prune). Each path has a different actor and needs a different control.

**Decision.** (1) The `ArgoCD` CR, both namespaces, the operator's Subscription/CSV/OperatorGroup, every `argoproj.io` CRD, AppProjects and Applications are critical, most of them by name so they are protected even before a label could be applied. (2) The guardrails Application has no cascade finalizer and `selfHeal: true`; ApplicationSets get `preserveResourcesOnDeletion`; Argo CD RBAC denies `delete` and `override` on applications and any create/update in the guardrails project to operators, so the UI/CLI cannot become a side door. (3) The Argo CD application and ApplicationSet controllers are the **GitOps path** and are exempt: what they apply was merged under the repository ruleset (two reviewers, code owners, CI invariants, signed commits), which is a stronger and better-audited approval than a cluster-side annotation. Their deletions are alerted (`GitOpsCriticalDeletionApplied`) and must correlate with a PR. `argocd-server` (UI/CLI) is not exempt. Argo CD is also the mechanism that heals the control: any out-of-band change to a policy object is reverted on the next reconcile.

**Why not the alternatives.** Making the controllers non-exempt would force every Git-approved deletion through a second, redundant approval on the cluster and would mean Git is no longer the source of truth. Protecting only by label would leave the namespace and CRDs, which cannot be labelled by Git before they exist, unprotected.

**Evidence.** docs/05; docs/14 tests T3.4–T3.6 (instance, namespace, CRD), T7 (Git-side prune denied), T8 (self-heal).

### 3.4 Alerts must reach the team in seconds by email and Teams

**Concern.** A control that blocks silently trains people to work around it; a deletion that succeeds (approved, or via break-glass) must still be seen by the owning team immediately; alert delivery itself must be resilient.

**Decision.** Twenty Loki alerting rules on the audit tenant (out-of-band deletion, Git-driven deletion, denied and would-be-denied attempts, approval activity, policy/RBAC/audit tampering, impersonation of approvers and of privileged identities, token minting, break-glass, kubeadmin, node access, credential secrets) with `interval 30s` and `for: 0s`, plus fifteen metrics rules that do not depend on the audit pipeline (Argo CD controller/server/operator missing, namespace Terminating, guardrail app out of sync, **audit ingestion stalled**, ruler down, reaper failing). Alertmanager 0.29 (shipped with OCP 4.21) routes `guardrail="true"` critical alerts to an email receiver and a native Microsoft Teams Workflows receiver (`msteamsv2_configs`) with `group_wait: 0s` and `repeat_interval: 30m`, and additionally to the existing on-call receiver so nothing is lost if Teams or SMTP fail. Templates carry actor, object, cluster, time and runbook link.

**Why not the alternatives.** A `prometheus-msteams` bridge: an extra deployment and the retired O365 connector format. Grouping delays: fine for capacity alerts, wrong for a deletion. Audit-only detection: stopping the forwarder would blind everything; the metrics pipeline catches exactly that.

**Evidence.** docs/06 catalogue; docs/14 tests T9 (synthetic and real delivery, timing), T10 (pipeline blind-spot alert).

### 3.5 The control must not be switchable off quietly

**Concern.** The first move of a capable attacker or a frustrated admin is to disable the guardrail, downgrade the audit profile or silence the alerts, then act.

**Decision.** Five layers: the policy objects, bindings, `GuardrailConfig`, `guardrails-*` RBAC and privileged groups are critical by name; the `-hardened` GitOps-only binding denies any change to them by anyone but the GitOps path, trusted mutators and break-glass in **every phase** (approval annotations excepted); approvers' RBAC is scoped by `resourceNames`; Argo CD self-heals them; every out-of-band write raises `GuardrailPolicyModified` (P1); the only legitimate path is a PR with two approvals and code-owner review under a ruleset with no bypass actors, checked by CI invariants that reject weakening (humans in exempt lists, `argocd-server` as a GitOps controller, `minApprovers < 2`, `Deny` removed, finalizer added, plaintext secrets).

**Residual.** Whether a VAP evaluates deletes of its own binding objects must be confirmed on the exact build (test T3.7). If not, layers 2–5 remain.

**Evidence.** docs/04 §Self-protection; docs/14 tests T3.7–T3.9, T8, T11 (Git-side).

### 3.6 Identity must be personal, minimal and loud when escalated

**Concern.** Shared accounts (`kubeadmin`), the installer's `system:admin` kubeconfig, standing `cluster-admin` for humans and impersonation all defeat attribution and make forged approvals possible.

**Decision.** IdP-backed personal identities and groups; `kubeadmin` removed; `system:admin` kubeconfig vaulted; `platform-admins` empty at rest with JIT membership; break-glass as a service account whose token is minted under dual control and expires in an hour; any write via impersonation, any use of `kube:admin`/`system:admin`/break-glass, any privileged RBAC or group change is a P1 alert. The rbac-escalation policy stamps such requests so the alert is exact, never blocking (`[Warn, Audit]`).

**Evidence.** docs/03; docs/14 tests T12 (impersonation alert), T13 (break-glass procedure and alert), T14 (privileged RBAC change alert).

### 3.7 Rollout must be safe for a production cluster

**Concern.** A policy that blocks unexpectedly can stop operators and pipelines.

**Decision.** Four kustomize overlays differ only in `validationActions`: audit (nothing blocked, everything annotated), warn (users see the exact message), enforce, gitops-only. Phase changes are PRs; each phase has exit criteria and a one-PR rollback. Bindings are scoped (label selector for labelled kinds, explicit low-traffic kinds by name) so the policy costs nothing on ordinary Secret/ConfigMap traffic and a missing parameter object cannot block unrelated workloads.

**Evidence.** docs/10; docs/14 tests T1 (phase-1 behaviour), T15 (phase-2 warning output).

### 3.8 It must be operable and provable

**Concern.** Controls that are hard to use get bypassed; controls that cannot be demonstrated fail audits.

**Decision.** Four scripts for the workflow with pre-checks and confirmations; a verify script for health; a phase-aware automated matrix producing an evidence log; runbooks for deletion, red alert, tampering, pipeline failure, break-glass, restore; recurring activities and KPIs; control mapping to ISO 27001, SOC 2, NIST 800-53, CIS, PCI DSS; an AI-assistant layer (`AGENTS.md`, skills, subagents, shared memory) so any operator or tool can perform the procedures consistently.

**Evidence.** docs/09, 11, 12; docs/14 in full.

### 3.9 Recovery must exist and be rehearsed

**Concern.** Prevention lowers probability; it does not make loss impossible (residual risks R1–R3, infrastructure loss).

**Decision.** Git as the primary source of truth; OADP 6-hourly backups of the GitOps namespaces with cluster-scoped dependants and a daily backup of the cluster-scoped guardrail objects, to an object-locked bucket separate from the Loki bucket; quarterly restore drill; cold-start runbook with RTO 10–30 minutes.

**Evidence.** docs/07; docs/14 test T16.

## 4. Alternatives considered and rejected

| Alternative | Why rejected |
|---|---|
| Rely on Argo CD `Prune=false` and sync windows only | Covers the Git path only; `oc delete` by a human is untouched |
| Rely on RBAC (remove `delete` from everyone) | Someone must be able to delete; that someone is then a single point of failure; `cluster-admin` cannot be restricted by RBAC |
| Finalizer-based "deletion protection" controllers | The DELETE succeeds (object enters Terminating); the protection can be removed by patching finalizers; no approval semantics |
| Kyverno / OPA Gatekeeper | Adds a webhook + operator + CRDs to protect; outage or removal of the webhook silently disables the control; acceptable as a second engine, unnecessary as the first |
| Approval tickets as separate CRs | VAP multi-parameter semantics ("valid against every matching param") and lack of a clock in CEL make single-ticket lookups unreliable; on-object annotations are self-cleaning and audited with the object |
| Make the Argo CD controllers non-exempt (cluster-side approval for Git changes too) | Redundant with the repository ruleset; Git would no longer be the source of truth; every reviewed removal would stall on a second approval |
| Exempt `argocd-server` as well | UI/CLI deletions are not Git-reviewed; they stay under the two-person rule |
| Slack/Teams via a bridge deployment | Extra component; Alertmanager 0.28+ has native Teams Workflows support |
| Audit-only detection | Blind if the forwarder is stopped; metrics pipeline added for exactly that |

## 5. What is proven, what is claimed, what is residual

| Statement | Status |
|---|---|
| Manifests build (5 kustomizations), lint clean, scripts parse, CI invariants pass, diagrams parse; two independent audits applied (docs/16) | **Proven locally** (docs/11, docs/16) |
| Versions: OCP 4.21 = K8s 1.34; Alertmanager 0.29.0 supports `msteamsv2_configs`; GitOps 1.19+ on 4.21; Logging 6 API `observability.openshift.io/v1` | **Verified against Red Hat documentation** (Sept 2026) |
| CEL compiles on the API server; every negative case denied; happy path allowed | **Proven on your cluster by docs/14** (first run in phase 1 on pre-prod) |
| VAP evaluates deletes of its own bindings | **To confirm** (T3.7); compensating layers exist either way |
| Three colluding people, control-plane node access, IdP or GitHub account compromise, impersonation of exempt identities by cluster-admin | **Residual**, with compensating controls in docs/01 |

## 6. Summary for the review board

The solution closes the stated requirements with a built-in, non-bypassable enforcement point (admission), a separation-of-duties model that the API server itself verifies, two independent detection pipelines feeding immediate multi-channel notification, self-protection of the control, hardened identity, a phased and reversible rollout, complete runbooks, automated and manual test evidence, compliance mapping and a documented residual-risk register. Nothing in it requires software outside Red Hat's supported OpenShift, Logging, GitOps and OADP products.
