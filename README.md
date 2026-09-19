# OpenShift 4.21 – Audit Trail, Critical-Resource Deletion Guardrails and Red Alerting

Production-grade controls for an OpenShift Container Platform 4.21 cluster that runs OpenShift GitOps (Argo CD):

| Requirement | How it is met | Where |
|---|---|---|
| Every edit and deletion is attributable (who, what, when, from where) | API-server audit profile `WriteRequestBodies`, forwarded to the SIEM (system of record) **and** to an in-cluster LokiStack (for alerting), 90-day in-cluster retention, object-locked buckets | [docs/02](docs/02-audit-logging.md), `manifests/01-audit` |
| No single person, **including cluster-admin**, can delete a critical resource **out of band** | `ValidatingAdmissionPolicy` inside kube-apiserver enforces a two-person rule for any direct API deletion: request + ≥ 2 distinct approvals + executor ≠ approver. Changes merged through Git (2 reviewers) and applied by the Argo CD controllers are the pre-approved GitOps path | [docs/04](docs/04-deletion-guardrails.md), `manifests/03-guardrails` |
| Argo CD itself cannot be removed by one authorised user | The `ArgoCD` CR, its namespace, operator Subscription/CSV, CRDs, AppProjects and Applications are all "critical": any direct deletion (oc, console, Argo CD UI) needs the workflow. Removal through Git needs the 2-reviewer PR and is alerted | [docs/05](docs/05-argocd-protection.md), `manifests/04-argocd` |
| Any deletion (or attempt) raises a red alert to **email and Microsoft Teams** within seconds | Loki `AlertingRule`s on the audit stream + metrics-based `PrometheusRule`s (second, audit-independent channel) → Alertmanager 0.29 with `email_configs` + `msteamsv2_configs` (Teams Workflows), `group_wait: 0s` | [docs/06](docs/06-alerting-and-notifications.md), `manifests/05-alerting` |
| Still recoverable if everything else fails | OADP schedules (6-hourly) + Git as source of truth + cold-start runbook | [docs/07](docs/07-backup-and-recovery.md), `manifests/06-backup` |
| The guardrails cannot be quietly switched off | Policy objects are themselves critical, GitOps-only in **every** phase (hardened binding), RBAC-scoped with `resourceNames`, self-healed by Argo CD, and every out-of-band write to them is a P1 alert. Git side: 2 reviewers + CODEOWNERS, no bypass | [docs/04 §self-protection](docs/04-deletion-guardrails.md#self-protection), [docs/08](docs/08-github-approval-workflow.md) |

Verified against: OCP 4.21 (Kubernetes 1.34, Alertmanager 0.29.0, Prometheus 3.7), OpenShift GitOps 1.19+, OpenShift Logging 6.x (`observability.openshift.io/v1`), Loki Operator 6.x, OADP 1.5.

## Trust model (read this first)

| Path | Who acts on the cluster | Approval | Cluster-side control |
|---|---|---|---|
| **GitOps path** | Argo CD application-controller / ApplicationSet controller applying a merged commit | the repository ruleset: 2 reviewers + code owners (`docs/08`) | **exempt** from the two-person rule (`GuardrailConfig.spec.gitopsControllers`); every Git-driven deletion of a critical object is still alerted as `GitOpsCriticalDeletionApplied` for PR correlation |
| **Out-of-band path** | humans with `oc`/console, Argo CD UI/CLI (acts as `argocd-server`, not Git-reviewed), any other controller, break-glass | the two-person rule on the cluster: request + 2 approvers + executor | `guardrails-critical-delete` (Deny in phase ≥ 3), label control, GitOps-only mutation for the self-protection set (Deny in every phase) |

Create/update/delete through Git needs no extra approval on the cluster. The same operation done directly against the API on a critical object needs the workflow, whoever the actor is, including cluster-admin.

## Architecture

```mermaid
flowchart TB
    subgraph L1["1 - Identity and RBAC"]
        IdP["IdP groups<br/>platform-admins JIT<br/>gitops-deletion-approvers<br/>gitops-deletion-requesters<br/>gitops-operators, auditors"]
    end
    subgraph L2["2 - Argo CD, openshift-gitops"]
        Git[("GitHub<br/>2 reviewers + CODEOWNERS")]
        ArgoCD["Argo CD app guardrails<br/>selfHeal on, prune off<br/>no cascade finalizer"]
        Git --> ArgoCD
    end
    subgraph API["kube-apiserver"]
        RBAC["RBAC"]
        VAP["3 - ValidatingAdmissionPolicy<br/>guardrails-critical-delete<br/>two-person rule in CEL"]
        Audit["5 - Audit log<br/>WriteRequestBodies + policy annotations"]
        RBAC --> VAP --> Audit
    end
    Users["Humans and CI<br/>oc or console"] --> RBAC
    IdP -.-> Users
    ArgoCD -- "applies: GitOps path, pre-approved by the PR ruleset" --> RBAC
    Audit --> Vector["Vector collector<br/>ClusterLogForwarder"]
    Vector --> SIEM[("Splunk or Elastic<br/>system of record, WORM")]
    Vector --> Loki[("LokiStack audit tenant<br/>90 days")]
    Loki --> Ruler["6 - Loki ruler<br/>AlertingRules on audit events"]
    Prom["6 - Prometheus<br/>PrometheusRules: Argo CD missing,<br/>namespace Terminating, ingestion stalled"]
    Ruler --> AM["7 - Alertmanager 0.29<br/>route guardrail=true, group_wait 0s"]
    Prom --> AM
    AM --> Email["Email<br/>platform + security on-call"]
    AM --> Teams["Microsoft Teams channel<br/>Workflows webhook, adaptive card"]
    OADP["8 - OADP schedules<br/>6h / 30d and daily / 90d"] -.-> API
    classDef control fill:#fde7e7,stroke:#b00020,color:#000
    classDef detect fill:#fff4e0,stroke:#b36b00,color:#000
    classDef notify fill:#e6f2ff,stroke:#0b5cad,color:#000
    class VAP control
    class Ruler,Prom,Audit detect
    class AM,Email,Teams notify
```

## The deletion workflow in one picture

```mermaid
sequenceDiagram
    autonumber
    participant R as Requester
    participant A1 as Approver 1
    participant A2 as Approver 2
    participant E as Executor
    participant API as kube-apiserver + VAP
    participant AM as Alertmanager
    R->>API: annotate delete-request and delete-requested-by = own username
    API-->>AM: info CriticalDeletionApprovalRecorded
    A1->>API: append delete-approvals entry approver1|timestamp
    Note over API: CEL checks: entry names the caller, caller in approver group,<br/>caller is not the requester, nothing else changed
    A2->>API: append delete-approvals entry approver2|timestamp
    E->>API: oc delete
    Note over API: CEL checks: request present, 2+ distinct approvers,<br/>executor is not an approver
    API-->>E: 200 deleted
    API-->>AM: CRITICAL CriticalResourceDeleted from audit log
    API-->>AM: CRITICAL ArgoCDApplicationControllerMissing from metrics
    AM-->>R: Email + Microsoft Teams card
    Note over R,AM: Any step that fails a CEL rule returns 403 and raises CriticalResourceDeleteDenied
```

## Repository layout

```
docs/                       numbered design + operations documents (start with 00 and 01)
manifests/base/             phase-3 (enforce) definitions, kustomize
manifests/overlays/phaseN   audit-only → warn → enforce → gitops-only (Argo CD points here)
manifests/0X-*/             one directory per layer, every file has a header: purpose, phase, rollback
scripts/                    request/approve/execute/cancel a deletion, verify-install, test matrix, audit query
.github/                    CODEOWNERS, ruleset (2 approvals, no bypass), policy CI
```

## Quick start (after reading docs/10-rollout-plan.md)

```bash
# 0. replace placeholders (docs/00-placeholders.md), commit through a 2-reviewer PR
# 1. phase 1 – audit only; nothing is blocked yet
oc apply --server-side -k manifests/overlays/phase1-audit
# 2. wire secrets from the vault: logging-loki-s3, splunk-hec, alertmanager-main (SMTP + Teams URL), cloud-credentials
# 3. verify
scripts/verify-install.sh
# 4. after ≥1 week clean: phase 2 (warn) → phase 3 (enforce) → phase 4 (gitops-only) by changing the Argo CD app path via PR
# 5. sign-off: scripts/test-guardrails.sh  (expects every negative case denied, happy path allowed, alerts received)
```

## Using this repository with AI assistants

Any LLM tool can operate this repository with a few hundred tokens of context:

| File | Read by | Purpose |
|---|---|---|
| `AGENTS.md` | Codex, Cursor, Copilot, Gemini CLI, Claude Code (via `CLAUDE.md`), others | hard rules, facts, commands, read map: the only file an assistant needs by default |
| `CLAUDE.md` | Claude Code | imports `AGENTS.md`, lists skills/subagents |
| `.claude/skills/*/SKILL.md` | Claude Code (`/guardrail-*`), any tool as plain procedures | delete, investigate, verify, rollout, incident |
| `.claude/agents/*.md` | Claude Code subagents | `guardrail-operator`, `audit-investigator` (read-only), `guardrail-change-reviewer` |
| `.claude/settings.json` | Claude Code | pre-allowed read-only commands; denies CRD/namespace/policy deletes, impersonation, break-glass token minting |
| `llm/context.yaml` | any tool | the facts, machine-readable |
| `llm/memory.md` | any tool | shared durable memory + state log (phase, tests, open risks): update it |
| `llms.txt` | any tool / crawler | index of the files above |
| `.github/copilot-instructions.md`, `.cursor/rules/guardrails.mdc` | Copilot, Cursor | one-line pointers to `AGENTS.md` |

## Document index

| # | Document | Read when |
|---|---|---|
| 00 | [Placeholders](docs/00-placeholders.md) | before the first apply |
| 01 | [Threat model & residual risk](docs/01-threat-model.md) | to understand what is and is not covered |
| 02 | [Audit logging](docs/02-audit-logging.md) | designing retention / SIEM / investigations |
| 03 | [Identity & RBAC hardening](docs/03-identity-rbac-hardening.md) | before enforcing (the guardrail is only as strong as this) |
| 04 | [Deletion guardrails (VAP/CEL)](docs/04-deletion-guardrails.md) | the core mechanism, rule by rule |
| 05 | [Argo CD protection](docs/05-argocd-protection.md) | GitOps-specific hardening |
| 06 | [Alerting & notifications](docs/06-alerting-and-notifications.md) | email/Teams setup, alert catalogue |
| 07 | [Backup & recovery](docs/07-backup-and-recovery.md) | RPO/RTO, restore drill |
| 08 | [GitHub approval workflow](docs/08-github-approval-workflow.md) | repo/branch protection |
| 09 | [Runbooks](docs/09-runbooks.md) | operating it day to day and in an incident |
| 10 | [Rollout plan](docs/10-rollout-plan.md) | phased enablement with exit criteria and rollback |
| 11 | [Testing & validation](docs/11-testing-and-validation.md) | sign-off evidence |
| 12 | [Operations & compliance](docs/12-operations-and-compliance.md) | recurring reviews, control mapping |
| 13 | [Solution justification](docs/13-solution-justification.md) | presenting the design to an architecture/security review board |
| 14 | [Manual test guide](docs/14-manual-test-guide.md) | step-by-step positive and negative tests with expected output |
| 15 | [Implementation guide](docs/15-implementation-guide.md) | the ordered, step-by-step rollout with verification, rollback and a tracking table |
| 16 | [Production readiness review](docs/16-production-readiness-review.md) | independent audit findings, what was fixed, and the 100 % test traceability matrix |
| – | [HTML portal](html/index.html) | entry point with summary and navigation to the study guide and HTML versions of every document (`node scripts/build-html-docs.mjs` regenerates `html/docs/`) |
| – | [Study guide (HTML)](html/study-guide.html) | complete technical study material, foundations to corner cases, with the gap-fix implementations |
