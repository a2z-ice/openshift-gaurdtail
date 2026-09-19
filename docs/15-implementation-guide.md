# 15 · Step-by-step implementation guide

Follow this document top to bottom to take the solution from an empty cluster to enforced guardrails in production. Every step states **who** does it, **what** to run, **how to verify**, **how to roll back**, and **what evidence to keep**. Steps reference the detailed documents rather than repeating them; open the referenced document only when a step says so.

Time estimates assume one platform engineer with the accesses listed in Part A, a pre-production cluster that mirrors production, and an existing on-call rotation. Total elapsed time is dominated by the observation windows (phase 1 and phase 2, one week each), not by hands-on work (about three working days in total).

```
Part A  Prepare            (1–2 days)   decisions, accesses, repository, placeholders, ruleset
Part B  Platform prereqs   (1 day)      identity, operators, storage, secrets, audit profile
Part C  Bootstrap pre-prod (½ day)      phase 1 on pre-prod, verify, test, alert test
Part D  Hand over to GitOps(½ day)      Argo CD owns the guardrails
Part E  Phase gates        (2–4 weeks)  1 → 2 → 3 → 4 with exit criteria
Part F  Production         (repeat C–E) with a change window for phase 3
Part G  Operate            (ongoing)    recurring activities, hand-over
```

Use the tracking table in Appendix 1 to record completion, dates and evidence.

---

## Part A · Prepare

### A1. Confirm the decisions this repository assumes
**Who:** platform lead + security lead. **Time:** 1 h.

| Decision | Assumed | If different |
|---|---|---|
| Admission engine | built-in ValidatingAdmissionPolicy | do not proceed with this repository; the design depends on it |
| Git provider | GitHub / GitHub Enterprise | port `.github/RULESET.md` to GitLab approval rules or Bitbucket merge checks |
| SIEM | Splunk HEC (Elasticsearch / syslog blocks provided) | swap the output block in `manifests/01-audit/clusterlogforwarder-audit.yaml` |
| In-cluster alerting store | LokiStack (Loki Operator) | required; Loki rules are the audit-based detection path |
| Notification | email + Microsoft Teams (Workflows webhook) | add/remove receivers in `manifests/05-alerting/alertmanager-main.yaml` |
| Backups | OADP to S3-compatible storage with Object Lock | adapt `manifests/06-backup/oadp-dpa.yaml` |
| Minimum approvers / executor rule | 2 approvers, executor ≠ approver (three people) for **out-of-band** deletions; Git changes are approved by the PR ruleset | `manifests/03-guardrails/guardrailconfig-default.yaml` (`minApprovers`, `executorMayBeApprover`); never below 2 |
| Trust model | GitOps path (Argo CD controllers) exempt; `argocd-server` not | `gitopsControllers` vs `gitopsServiceAccounts` in the same file |

Record the outcome in the change ticket that will carry the whole rollout.

### A2. Assemble the people
**Who:** platform lead. **Time:** ½ day (mostly waiting on HR/IdP).

| Role | Minimum | Group |
|---|---|---|
| Deletion approvers | 4 people across 2 teams | `gitops-deletion-approvers` |
| Requesters/executors | 2 | `gitops-deletion-requesters` |
| Argo CD day-2 operators | as needed | `gitops-operators` |
| Auditors | 1 | `auditors` |
| JIT platform admins | as needed, **empty at rest** | `platform-admins` (bound to `guardrails-platform-admin` + `guardrails-impersonator`, not `cluster-admin`; docs/17) |
| Break-glass custodians | 2, different teams | `breakglass-custodians` (may mint the token) |
| GitHub code owners | ≥ 3 each in `@example-org/platform-engineering` and `@example-org/security` | CODEOWNERS |

### A3. Tools on the engineer's workstation
```bash
oc version --client        # 4.21 client
kustomize version          # ≥ 5.4
yamllint --version
node --version             # for the diagram check only
gh --version               # GitHub CLI for the ruleset
logcli --version           # optional, for audit queries
amtool --version           # optional; the runbooks exec it inside the Alertmanager pod
```

### A4. Fork/clone the repository and replace placeholders
**Who:** platform engineer. **Time:** 1 h. **Reference:** `docs/00-placeholders.md`.

1. Create the GitHub repository `example-org/openshift-administration` (or your names) and push this content to `main`.
2. Replace every placeholder in one commit. The label prefix `guardrails.example.com` must be changed **once, now**, because it is baked into the CRD group and the CEL:
   ```bash
   NEW=guardrails.acme.io
   grep -RIl 'guardrails\.example\.com' manifests docs scripts .github llm .claude AGENTS.md CLAUDE.md README.md html | xargs sed -i "s/guardrails\.example\.com/${NEW}/g"
   # then the org/repo, team names, e-mail addresses, SMTP host, SIEM URL, buckets, regions, storage class, cluster label
   ```
3. Run the check at the bottom of `docs/00-placeholders.md`; it must print nothing except the `REPLACE_*` secret placeholders.
4. Validate locally:
   ```bash
   for o in manifests/base manifests/overlays/*; do kustomize build "$o" >/dev/null && echo "OK $o"; done
   yamllint -c .yamllint manifests && bash -n scripts/*.sh
   ```
**Verify:** all overlays build with the same object count (84). **Evidence:** the commit SHA.

### A5. Protect the repository
**Who:** GitHub org admin + platform engineer. **Time:** 30 min. **Reference:** `docs/08`, `.github/RULESET.md`.
```bash
gh api -X POST repos/example-org/openshift-administration/rulesets --input .github/ruleset-main.json
gh api -X PATCH repos/example-org/openshift-administration -f allow_merge_commit=false -f allow_rebase_merge=false -f allow_squash_merge=true -f delete_branch_on_merge=true
gh api -X PATCH repos/example-org/openshift-administration -f 'security_and_analysis[secret_scanning][status]=enabled' -f 'security_and_analysis[secret_scanning_push_protection][status]=enabled'
```
Populate the two code-owner teams. Optionally add the `PREPROD_KUBECONFIG` secret (a token for a read-only + dry-run service account on pre-prod) so CI can `oc apply --dry-run=server`.

**Verify:** `gh api repos/.../rules/branches/main --jq '.[].type'` lists `pull_request`, `required_status_checks`, `required_signatures`, `deletion`, `non_fast_forward`, `required_linear_history`. Open a throw-away PR and confirm the `validate` check runs and two approvals are required.

From this point on, **every change to the repository is a PR**.

---

## Part B · Platform prerequisites (per cluster; do pre-prod first)

### B1. Identity provider and groups
**Who:** platform engineer + IdP team. **Time:** ½ day. **Reference:** `docs/03`.

1. Confirm the IdP login works and yields a stable personal username: `oc whoami` → `alice@example.com`.
2. Create the groups from the directory. Either an OIDC `groups` claim, or apply `manifests/07-hardening-extras/ldap-group-sync.example.yaml` after filling in the LDAP details and creating the `ldap-sync` / `ldap-ca` secrets. As a bootstrap only, `manifests/00-namespaces-and-groups/groups.yaml` can be applied with real usernames.
3. Verify membership:
   ```bash
   oc get group gitops-deletion-approvers gitops-deletion-requesters platform-admins -o custom-columns=NAME:.metadata.name,USERS:.users
   ```
4. Remove `kubeadmin` **only after** an IdP user with JIT `platform-admins` membership has successfully run an admin command:
   ```bash
   oc delete secret kubeadmin -n kube-system
   ```
5. Move the installer's `auth/kubeconfig` into the vault under dual control and delete local copies.

**Verify:** `scripts/verify-install.sh` section "Identity" shows kubeadmin removed and ≥ 4 approvers. **Rollback:** kubeadmin cannot be recreated; this is why step 4 waits for a working IdP admin.

### B2. Operators
**Who:** platform engineer. **Time:** 1 h + operator install time. **Reference:** `docs/02`, `docs/07`.

| Operator | Namespace | Manifest | Check |
|---|---|---|---|
| OpenShift GitOps (already present) | `openshift-gitops-operator` | cluster-config repo | `oc get argocd openshift-gitops -n openshift-gitops` |
| OpenShift Logging 6.x | `openshift-logging` | `manifests/01-audit/operators.yaml` | `oc get csv -n openshift-logging` → Succeeded |
| Loki Operator 6.x | `openshift-operators-redhat` | same file | `oc get csv -n openshift-operators-redhat` |
| OADP | `openshift-adp` | `manifests/06-backup/oadp-dpa.yaml` (Subscription part) | `oc get csv -n openshift-adp` |

Verify channel names first: `oc get packagemanifest -n openshift-marketplace cluster-logging loki-operator redhat-oadp-operator -o custom-columns=NAME:.metadata.name,CHANNEL:.status.defaultChannel`, and adjust the `channel:` fields via PR if they differ.

### B3. Object storage
**Who:** cloud/storage team. **Time:** 1 h.

Two buckets, versioning on, **Object Lock** (compliance mode) with retention ≥ 90 days for Loki and ≥ 30/90 days for OADP, IAM users without `DeleteObject`:

| Bucket | Used by | Secret |
|---|---|---|
| `ocp-audit-loki` | LokiStack | `openshift-logging/logging-loki-s3` |
| `ocp-prod-eu-1-oadp` | OADP | `openshift-adp/cloud-credentials` (key `cloud`) |

### B4. Secrets from the vault
**Who:** platform engineer with vault access. **Time:** 1 h. Never commit these.

| Secret | Namespace | Keys | Source manifest to read |
|---|---|---|---|
| `logging-loki-s3` | `openshift-logging` | `access_key_id`, `access_key_secret`, `bucketnames`, `endpoint`, `region` | `manifests/01-audit/loki-s3-secret.example.yaml` |
| `splunk-hec` | `openshift-logging` | `hecToken` | `clusterlogforwarder-audit.yaml` |
| `splunk-ca` (ConfigMap, optional) | `openshift-logging` | `ca-bundle.crt` | same |
| `cloud-credentials` | `openshift-adp` | `cloud` | `oadp-dpa.yaml` |
| `alertmanager-main` | `openshift-monitoring` | `alertmanager.yaml`, `guardrail.tmpl` | `manifests/05-alerting/alertmanager-main.yaml` (render with the SMTP password and Teams URL) |

Create the Teams webhook first (Part B6) so its URL can be rendered into `alertmanager-main`.

### B5. Audit profile
**Who:** platform engineer. **Time:** 15 min + 15 min roll. **Reference:** `docs/02`.
```bash
oc apply --server-side --field-manager=guardrails -f manifests/01-audit/apiserver-audit.yaml
oc get co kube-apiserver -w        # PROGRESSING=True while pods roll, then False
oc get apiserver cluster -o jsonpath='{.spec.audit}'; echo
```
**Verify:** `oc adm node-logs --role=master --path=kube-apiserver/audit.log | tail -1 | python3 -m json.tool | grep -c requestObject` → a write event now carries `requestObject`. Watch `/var` usage on masters for a week. **Rollback:** patch `profile: Default` (after phase 3 this needs approvals by design).

### B6. Microsoft Teams webhook and SMTP
**Who:** Teams channel owner + platform engineer. **Time:** 30 min. **Reference:** `docs/06` §Teams.

1. In the target channel: **… → Workflows → "Post to a channel when a webhook request is received"** → copy the URL. Store it in the vault.
2. Confirm the SMTP relay (host, port 587, TLS, auth user) and a sender address; store the password in the vault.
3. Render `alertmanager.yaml` and `guardrail.tmpl` from `manifests/05-alerting/alertmanager-main.yaml` with the real values, **merging** your existing receivers/routes, then:
   ```bash
   oc -n openshift-monitoring create secret generic alertmanager-main --from-file=alertmanager.yaml --from-file=guardrail.tmpl --dry-run=client -o yaml | oc replace -f -
   oc -n openshift-monitoring label secret alertmanager-main guardrails.example.com/critical=true --overwrite
   oc -n openshift-monitoring exec alertmanager-main-0 -c alertmanager -- amtool check-config /etc/alertmanager/config_out/alertmanager.env.yaml
   ```
4. Fire the synthetic alert from `docs/06` (`amtool alert add ...`).

**Verify:** Teams card and e-mail within ~10 s; `[RESOLVED]` after 5 min. **Evidence:** screenshot of both. **Rollback:** restore the previous secret content (keep a copy before `oc replace`).

### B7. Logging stack and forwarder
**Who:** platform engineer. **Time:** 1 h. **Reference:** `docs/02`.
```bash
oc apply -f manifests/01-audit/lokistack.yaml                 # after editing storageClassName
oc get lokistack logging-loki -n openshift-logging -w         # Ready
oc apply -f manifests/01-audit/clusterlogforwarder-audit.yaml
oc get clusterlogforwarder audit-forwarder -n openshift-logging -o jsonpath='{range .status.conditions[*]}{.type}={.status} {end}'; echo
oc get ds -n openshift-logging audit-forwarder                # pods on every node incl. masters
```
**Verify:** audit lines in the SIEM index and in Loki (`sum(rate(loki_distributor_lines_received_total{tenant="audit"}[5m]))` > 0 in the console's Observe → Metrics). **Rollback:** delete the CLF (needs approvals after phase 3).

### B8. Backups
**Who:** platform engineer. **Time:** 30 min. **Reference:** `docs/07`.
```bash
oc apply -k manifests/06-backup
oc -n openshift-adp get backupstoragelocation -o custom-columns=NAME:.metadata.name,PHASE:.status.phase
oc -n openshift-adp create backup initial --from-schedule=gitops-6h && oc -n openshift-adp get backup initial -w
```
**Verify:** phase `Completed`, items > 0. Do the restore drill from `docs/07` once now, so the first real restore is not the first ever.

---

## Part C · Bootstrap on pre-production (phase 1, audit only)

Nothing in phase 1 blocks anything. It installs every object, stamps audit annotations, and lets you observe.

### C1. Apply phase 1 by hand (once)
**Who:** platform engineer with JIT `platform-admins`. **Time:** 30 min.
```bash
oc apply --server-side --field-manager=guardrails -k manifests/overlays/phase1-audit
```
The order inside the base handles CRD-before-CR. If the `GuardrailConfig` apply races the CRD, re-run the command.

**Verify:**
```bash
oc get vap,vapb -l app.kubernetes.io/part-of=guardrails
oc get vap guardrails-critical-delete -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'; echo    # True
oc get vap guardrails-critical-delete -o jsonpath='{.status.typeChecking}' | head -c 600; echo               # warnings OK, errors not
oc get vapb -l app.kubernetes.io/part-of=guardrails -o custom-columns=NAME:.metadata.name,ACTIONS:.spec.validationActions   # [Audit] on deletion/label/gitops-only bindings
scripts/verify-install.sh
```
**Rollback:** `oc delete -k manifests/overlays/phase1-audit` (only in phase 1/2; later it needs approvals by design).

### C2. Run the automated matrix in phase-1 mode
**Who:** platform engineer. **Time:** 20 min. **Reference:** `docs/11`.
```bash
scripts/test-guardrails.sh
```
The script is phase-aware and must PASS in phase 1 (deny cases are expected to succeed); the evidence is the audit annotation and the `CriticalDeleteWouldBeDenied` alerts. Confirm with:
```logql
{log_type="audit"} | json | objectRef_namespace="guardrails-test" | annotations_validation_policy_admission_k8s_io_validation_failure=~".+"
```
**Evidence:** `evidence-<ts>.log` plus the LogQL output attached to the ticket.

### C3. Answer residual risk R3
**Who:** platform engineer. **Time:** 10 min.
```bash
oc delete validatingadmissionpolicybinding guardrails-critical-delete-named --dry-run=server
```
Check whether the audit event carries the `validation_failure` annotation (the policy evaluated its own kind) or not. Record the answer in `docs/01` §Residual-risk register and `llm/memory.md`.

### C4. Prove alert delivery end to end
**Who:** platform engineer + on-call. **Time:** 30 min. **Reference:** `docs/14` §9.

Delete a labelled scratch ConfigMap through the full workflow (T5.1). Time: audit `requestReceivedTimestamp` → Alertmanager `startsAt` → Teams post. Target ≤ 60 s. Also confirm `CriticalResourceDeleteDenied` (phase 1 shows it as the would-have-been-denied signal) and `ImpersonationUsed` if you used impersonation.

**Evidence:** screenshots and timings.

---

## Part D · Hand the guardrails to Argo CD

### D1. Harden the ArgoCD CR
**Who:** platform engineer (Argo CD admin). **Time:** 30 min. **Reference:** `docs/05`.
```bash
oc apply --server-side --field-manager=guardrails -f manifests/04-argocd/argocd-cr-hardening-patch.yaml
oc get argocd openshift-gitops -n openshift-gitops -o jsonpath='{.spec.disableAdmin} {.spec.rbac.defaultPolicy}{"\n"}'   # true role:readonly
```
Log in to the Argo CD UI via SSO; confirm `gitops-operators` cannot delete an Application (button disabled / 403).

### D2. Create the AppProject and the app-of-apps
```bash
oc apply -f manifests/04-argocd/appproject-guardrails.yaml
oc apply -f manifests/04-argocd/application-guardrails.yaml      # spec.source.path = manifests/overlays/phase1-audit at this point
oc get application guardrails -n openshift-gitops -o jsonpath='{.status.sync.status} {.status.health.status}{"\n"}'   # Synced Healthy
```
From now on Argo CD owns every object under `manifests/`; do not `oc apply` them by hand again.

### D3. Prove self-protection and self-heal
As a JIT admin, `oc patch validatingadmissionpolicybinding guardrails-critical-delete-labelled --type merge -p '{"spec":{"validationActions":["Audit"]}}'` → denied by the hardened binding (T8.1). Then, using break-glass on pre-prod only, make the same patch, wait ≤ 3 min, confirm Argo CD reverted it and `GuardrailPolicyModified` + `BreakGlassUsed` reached Teams.

### D4. Remove cascade finalizers from existing production Applications
**Who:** Argo CD operators, per application owner. **Time:** varies. **Reference:** `docs/05` §Applications.
```bash
oc get application -n openshift-gitops -o custom-columns=NAME:.metadata.name,FINALIZERS:.metadata.finalizers,PRUNE:.spec.syncPolicy.automated.prune
# for each production app that should NOT cascade:
oc -n openshift-gitops patch application <app> --type json -p '[{"op":"remove","path":"/metadata/finalizers"}]'
```
Label production Applications and ApplicationSets `guardrails.example.com/critical=true` in Git and set `preserveResourcesOnDeletion: true` on ApplicationSets (snippet in `manifests/04-argocd/applicationset-defaults-snippet.yaml`). `prune: true` stays where the application repository enforces two reviewers. Do this through the application repositories' own PRs.

---

## Part E · Phase gates

Each promotion is one PR that changes `spec.source.path` in `manifests/04-argocd/application-guardrails.yaml`. Argo CD applies the new `validationActions`. **Reference:** `docs/10` (criteria), `.claude/skills/guardrail-rollout/SKILL.md` (procedure).

### E1. Phase 1 → 2 (warn)
**Gate:** VAP `Ready=True`; R3 recorded; 7 consecutive days with zero unexplained `CriticalResourceDeleteDenied`/`ArgoCDDirectMutation` events (every one either became a workflow adoption or an identity added to `gitopsServiceAccounts`/`reaperUsers` by PR, never a human in `exemptUsers`); every approver has run `scripts/approve-deletion.sh` on a scratch object.
**Do:** PR `path: manifests/overlays/phase2-warn`. After merge: `oc get vapb ... -o custom-columns=NAME:.metadata.name,ACTIONS:.spec.validationActions` shows `[Warn Audit]`.
**Verify:** T15 (`oc delete ... --dry-run=server` prints the `Warning:` line and succeeds).

### E2. Phase 2 → 3 (enforce)
**Gate:** 7 days with zero warnings from pipelines and operators; on-call acknowledged a synthetic red alert; `scripts/test-guardrails.sh` PASS on pre-prod (all cases); break-glass rehearsal ≤ 30 days (T13); restore drill ≤ 90 days (T16); runbooks read by the on-call rotation.
**Do:** change window; PR `path: manifests/overlays/phase3-enforce`. Note that the self-protection set (`-hardened` binding) has been enforced since phase 1; phase 3 adds the two-person rule for every other critical object.
**Verify immediately:**
```bash
oc delete argocd openshift-gitops -n openshift-gitops --dry-run=server      # Error ... GUARDRAIL DENIED
scripts/verify-install.sh
scripts/test-guardrails.sh                                                   # all PASS
```
**Rollback:** reverse PR (two approvals; Argo CD applies it). Emergency only: break-glass edits `validationActions` (alerted, incident, post-mortem).

### E3. Phase 3 → 4 (GitOps-only mutation)
**Gate:** 14 days with zero `ArgoCDDirectMutation`; every controller that legitimately writes critical objects is in `gitopsServiceAccounts` (Argo CD server/controller/appset, GitOps operator, and if applicable External Secrets, Velero).
**Do:** PR `path: manifests/overlays/phase4-gitops-only`.
**Verify:** T2.2 now denies a human edit; UI sync of a critical Application still works (T-case 26 in the study guide's catalogue).

---

## Part F · Production

Repeat Parts B (per cluster), C, D and E on production with these differences:

1. Use a change ticket per phase; phase 3 in a change window with the security team on the bridge.
2. Run the sign-off matrix with **real user logins** (`IMPERSONATE=false`, four kubeconfigs) so no `ImpersonationUsed` alerts are generated on production.
3. Set the forwarder's `cluster` label to the production cluster identifier and route production alerts to the production Teams channel (a second `msteamsv2_configs` receiver and a `matchers: [cluster="prod-..."]` route if you want per-cluster channels).
4. Keep the pre-prod cluster at the same phase as production or one ahead; run the matrix there after every OpenShift, Logging, GitOps or Loki operator upgrade before upgrading production.

---

## Part G · Operate

### G1. Hand-over checklist
- [ ] On-call rotation has read `docs/09` (runbooks) and can find the Teams channel and e-mail list.
- [ ] Approvers know `scripts/approve-deletion.sh`; requesters know `request`/`execute`/`cancel`.
- [ ] Break-glass custodians named, vault dual-control policy tested, rehearsal date recorded.
- [ ] `docs/12` recurring activities scheduled in the team calendar (monthly synthetic alert, quarterly recertification, quarterly restore drill, per-upgrade test run).
- [ ] `llm/memory.md` state log updated with the phase per cluster and the last test run.
- [ ] Compliance evidence folder created (per `docs/11` §Evidence).

### G2. Adding a new critical object later
1. Label it in Git (`guardrails.example.com/critical: "true"`); if it is a new kind, add the kind to the three policies' `matchConstraints`, the reaper's resource list, the RBAC roles, the test matrix and `docs/04`. PR with security review.
2. If a controller writes it, add the controller's service account to `gitopsServiceAccounts` (never to `exemptUsers`).

### G3. Removing a critical object later
Run the workflow (`docs/09` §Request), then remove it from Git in the same change window.

---

## Appendix 1 · Tracking table

| Step | Done | Date | By | Evidence (ticket / SHA / screenshot) |
|---|---|---|---|---|
| A1 decisions | | | | |
| A2 people and groups | | | | |
| A3 tools | | | | |
| A4 placeholders replaced, local build OK | | | | |
| A5 ruleset, teams, secret scanning | | | | |
| B1 IdP, groups, kubeadmin removed, kubeconfig vaulted | | | | |
| B2 operators | | | | |
| B3 buckets with Object Lock | | | | |
| B4 secrets created | | | | |
| B5 audit profile, roll complete | | | | |
| B6 Teams + SMTP, synthetic alert received | | | | |
| B7 LokiStack + forwarder Ready, lines flowing | | | | |
| B8 first backup Completed, restore drill | | | | |
| C1 phase 1 applied, verify-install PASS | | | | |
| C2 matrix run, annotations observed | | | | |
| C3 R3 answered | | | | |
| C4 end-to-end alert timing ≤ 60 s | | | | |
| D1 ArgoCD CR hardened | | | | |
| D2 AppProject + Application Synced | | | | |
| D3 self-protection + self-heal proven | | | | |
| D4 finalizers removed, apps labelled | | | | |
| E1 phase 2 | | | | |
| E2 phase 3 | | | | |
| E3 phase 4 | | | | |
| F production, per cluster | | | | |
| G1 hand-over | | | | |

## Appendix 2 · Command index

| Purpose | Command |
|---|---|
| Build everything locally | `for o in manifests/base manifests/overlays/*; do kustomize build "$o" >/dev/null && echo "OK $o"; done` |
| Lint | `yamllint -c .yamllint manifests` |
| Apply a phase by hand (bootstrap only) | `oc apply --server-side --field-manager=guardrails -k manifests/overlays/phase1-audit` |
| Health | `scripts/verify-install.sh` |
| Automated matrix | `scripts/test-guardrails.sh` (`IMPERSONATE=false ...` for sign-off) |
| Smoke test (must deny in phase ≥ 3) | `oc delete argocd openshift-gitops -n openshift-gitops --dry-run=server` |
| Current phase | `oc get application guardrails -n openshift-gitops -o jsonpath='{.spec.source.path}'` |
| Binding actions | `oc get vapb -l app.kubernetes.io/part-of=guardrails -o custom-columns=NAME:.metadata.name,ACTIONS:.spec.validationActions` |
| Deletion workflow | `scripts/request-deletion.sh`, `approve-deletion.sh` ×2, `execute-deletion.sh`, `cancel-deletion.sh` |
| Who did what | `scripts/audit-query.sh <name>` |
| Synthetic alert | see `docs/06` §Teams |

## Appendix 3 · Where each requirement is proven

| Requirement | Implemented by | Proven by |
|---|---|---|
| Audit trail with who/what/when and bodies | B5, B7 | C2 LogQL evidence; `docs/14` §2 |
| No single person deletes a critical object | C1 (phase 3 via E2) | `docs/14` §3, §4 |
| Argo CD protected on all three paths | C1, D1, D2, D4 | `docs/14` §3.4–3.6, §7 |
| Alerts to e-mail and Teams in seconds | B6, B7 | B6 synthetic, C4 timing, `docs/14` §9 |
| Recoverable | B8 | `docs/14` §16 |
| Control cannot be quietly disabled | A5, D3 | `docs/14` §8, §11 |
