# 12 · Operations and compliance

## Recurring activities

| Cadence | Activity | Owner | Evidence |
|---|---|---|---|
| Continuous | On-call acknowledges guardrail alerts within 5 min; every `CriticalResourceDeleted` maps to a change ticket | Platform on-call | Teams thread + ticket |
| Weekly | Review `CriticalResourceDeleteDenied`, `ArgoCDDirectMutation`, `ImpersonationUsed` counts; tune false positives via PR (never via `exemptUsers` for humans) | Platform | dashboard export |
| Monthly | Synthetic alert (`amtool alert add`) → Teams + email delivery confirmed; SMTP/Teams webhook rotation check | Platform | screenshot |
| Monthly | `scripts/verify-install.sh` on every cluster | Platform | output in ticket |
| Quarterly | Access recertification: members of `platform-admins`, `gitops-deletion-approvers`, `gitops-deletion-requesters`, GitHub code-owner teams, vault break-glass custodians | Security + team leads | signed list |
| Quarterly | Restore drill (docs/07) | Platform | drill record |
| Quarterly | Break-glass rehearsal on pre-prod (docs/09) | Security | incident record |
| Per upgrade (OCP, Logging, GitOps, Loki) | `scripts/test-guardrails.sh` on pre-prod, then prod smoke test | Platform | evidence log |
| Annually | Threat model and residual-risk register review (docs/01); full Argo CD cold-start rehearsal | Security + Platform | updated docs |

## Dashboards (suggested panels, Grafana / console)

- Guardrail events over time by alertname (Loki `count_over_time` of `annotations_guardrails_critical_delete_decision`).
- Denied deletions by user (top 10) and by resource kind.
- Approvals recorded vs deletions executed (should be ≥ 2:1).
- Time from audit event to alert `startsAt` (p95 ≤ 60 s).
- Audit ingestion rate per API server and per tenant; forwarder buffer size.
- Argo CD sync status of the `guardrails` app.

## KPIs

| KPI | Target |
|---|---|
| Unapproved critical deletions | 0 |
| Detection latency (audit → alert) p95 | ≤ 60 s |
| Alert acknowledgement | ≤ 5 min |
| Approvers available (members / required) | ≥ 2× |
| Break-glass uses per quarter | 0 (each one has a post-mortem) |
| Restore drill success | 100 % |

## Control mapping

| Framework | Control | Implemented by |
|---|---|---|
| ISO/IEC 27001:2022 | A.5.15 Access control, A.5.18 Access rights, A.8.2 Privileged access rights | docs/03, RBAC, JIT `platform-admins`, break-glass |
| | A.8.15 Logging, A.8.16 Monitoring activities | docs/02, docs/06 |
| | A.8.13 Information backup | docs/07 |
| | A.8.32 Change management | docs/08, docs/10 |
| | A.5.3 Segregation of duties | two-person rule (requester / approvers / executor) |
| SOC 2 (TSC) | CC6.1–CC6.3 logical access; CC7.2–CC7.3 monitoring & incident response; CC8.1 change management; A1.2 backup | as above |
| NIST SP 800-53 r5 | AC-3(2) dual authorization, AC-5 separation of duties, AC-6(9) log privileged use, AU-2/AU-3/AU-6/AU-9 audit generation, content, review, protection (WORM), AU-11 retention, CM-3 change control, CM-5 access restrictions for change, CP-9/CP-10 backup & recovery, IR-4/IR-6 incident handling & reporting, SI-4 monitoring | mapped per row above |
| CIS OpenShift Benchmark | 1.2.x API server audit; 3.2 audit log policy; 5.x RBAC | docs/02, docs/03 |
| PCI DSS 4.0 | 7.2 least privilege; 8.x identity; 10.2–10.5 audit trails and protection; 10.7 detection of failures of critical security control systems | docs/03, docs/02, metrics alerts on pipeline health |

## Change management for this repository

Every change is a PR with two approvals (docs/08). Changes to `GuardrailConfig`, the policies, `exemptUsers`, groups or alert routing additionally require a security reviewer (CODEOWNERS). Emergency changes follow the break-glass runbook and get a post-mortem.

## Documentation upkeep

Each document has a "Verification" section; when a verification command changes because of an upgrade, the PR that upgrades the operator updates the document. `docs/01` residual-risk register is reviewed at every quarterly recertification.
