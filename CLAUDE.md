# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

@AGENTS.md

AGENTS.md (imported above) is the single source for hard rules, facts, commands and the read map; do not duplicate it here. This file adds what is Claude-specific and the cross-file architecture that AGENTS.md only summarises.

## Claude Code specifics

- Skills: `/guardrail-delete`, `/guardrail-investigate`, `/guardrail-verify`, `/guardrail-rollout`, `/guardrail-incident` (`.claude/skills/`).
- Subagents: `guardrail-operator` (runs scripts, needs `oc`), `audit-investigator` (read-only), `guardrail-change-reviewer` (reviews a diff against the hard rules and CI invariants). Prefer `audit-investigator` for any "who did what" question and `guardrail-change-reviewer` before proposing any manifest change.
- `.claude/settings.json` pre-allows read-only `oc get/describe/whoami/auth can-i`, kustomize, yamllint, git read commands; it denies CRD/namespace/policy deletes, `oc --as`, and minting the break-glass token. Anything else that writes to a cluster prompts.
- `oc` is not installed on the development machine; cluster steps are documented for the user to run. Local validation needs `kustomize`, `yamllint`, `node` (for the Mermaid check) and `python3`.
- Update `llm/memory.md` at the end of a session that changed phase, ran tests, or learned something not derivable from the repo.

## Build, lint, test

```bash
# full local validation (what CI runs, minus kubeconform/shellcheck which may not be installed)
for o in manifests/base manifests/overlays/*; do kustomize build "$o" >/dev/null && echo "OK $o"; done   # expect 91 objects each
yamllint -c .yamllint manifests
bash -n scripts/*.sh
npm i --no-save mermaid@11 jsdom dompurify marked && node scripts/check-mermaid.mjs README.md docs/*.md
node scripts/build-html-docs.mjs            # regenerate html/docs/ after editing any Markdown (CI fails if stale)
# CI guardrail invariants (Python over parsed YAML, embedded in policy-ci.yaml); run them locally with:
sed -n "/python3 - <<'PY'/,/^ *PY$/p" .github/workflows/policy-ci.yaml | sed '1d;$d' | sed 's/^          //' | python3
# inspect what a phase overlay actually changes
kustomize build manifests/overlays/phase3-enforce | grep -A3 validationActions
```

Tests against a cluster (user runs them):

```bash
scripts/verify-install.sh                       # health of every layer, exit 1 on hard failure
scripts/test-guardrails.sh                      # phase-aware matrix in scratch ns guardrails-test; writes evidence/<ts>.log
IMPERSONATE=false KUBECONFIG_REQUESTER=… KUBECONFIG_APPROVER1=… KUBECONFIG_APPROVER2=… KUBECONFIG_EXECUTOR=… scripts/test-guardrails.sh   # sign-off mode
```

The default (impersonation) mode forges the authentication markers with `--as-user-extra` (`HUMAN_EXTRA`, `SA_EXTRA`), which only a `system:masters` credential may do, so it runs on pre-prod with the installer kubeconfig; JIT `platform-admins` cannot run it by design (docs/17). Sign-off mode skips the service-account-identity cases.

There is no way to run a single automated case; to reproduce one, take its `expect …` line from `scripts/test-guardrails.sh` or the matching T-number in `docs/14-manual-test-guide.md` and run the command by hand.

## Architecture: how the pieces connect

The repository is one Argo CD Application (`manifests/04-argocd/application-guardrails.yaml`) whose `spec.source.path` selects a phase overlay; the overlays differ **only** in `validationActions` of the policy bindings and in that path. Reading order to understand a change end to end:

1. **`manifests/03-guardrails/crd-guardrailconfig.yaml` + `guardrailconfig-default.yaml`** define the single parameter object every policy reads via `paramRef` (`minApprovers`, groups, exempt/reaper/GitOps identities, TTL).
2. **`vap-critical-delete.yaml`** is the control. `variables` compute "is critical" (label OR name rules), parse the three `guardrails.example.com/delete-*` annotations from `oldObject`/`object`, and derive `deletionApproved`. `validations` V1 (DELETE), V2 (label removal), V3 (approval append integrity), V4 (request integrity). `auditAnnotations.decision` is what the Loki alerts key on.
3. **`vap-deletion-tracker.yaml`** never denies (`failurePolicy: Ignore`, binding `[Audit]`): it stamps `guardrails-deletion-tracker/state` (`event`, `have`, `need`, `remaining`, expiries) into the audit event of each workflow step; the approvers' notifications and reminders (`audience="approvers"`) are Loki rules on it. Lifetimes are enforced by the reaper: approvals `approvalTTL` 4h, the request `requestTTL` 24h from `delete-requested-at` (docs/19).
4. **`vap-critical-delete-bindings.yaml`**: binding `-labelled` uses an `objectSelector` (evaluated against object OR oldObject) and fails closed; binding `-named` lists low-traffic kinds without a selector and uses `parameterNotFoundAction: Allow` so a missing `GuardrailConfig` cannot block OLM or the namespace lifecycle. `GuardrailConfig.spec.gitopsControllers` (Argo CD application/ApplicationSet controllers) are exempt: the GitOps path is pre-approved by the PR ruleset.
5. **`vap-impersonation-dry-run-only.yaml`** (impersonated writes only with `--dry-run=server`; identity markers in `userInfo.extra`), **`vap-critical-label-control.yaml`** (who may add the critical label), **`vap-gitops-only-mutation.yaml`** (binding `guardrails-gitops-only-mutation` is Audit until phase 4; binding `-hardened` is Deny in every phase for the self-protection set) and **`vap-rbac-escalation-audit.yaml`** (never denies; its "failure" stamps the audit event) reuse the same variable patterns.
6. **`reaper-cronjob.yaml`**: CEL has no clock, so approval TTL is a CronJob whose SA the policy allows to *remove* entries only.
7. **`manifests/02-rbac`** is least-privilege (`platform-admin.yaml`: humans and break-glass get `guardrails-platform-admin`, never `cluster-admin`, so nobody can impersonate `userextras`): cluster-scoped kinds via `resourceNames`, namespaced kinds via `rolebindings.yaml` in the platform namespaces only; Tier-B kinds (namespaces, CRDs, OLM, Secrets, ServiceAccounts) have no human patch/delete at all. `breakglass.yaml` adds the custodian Role for minting the break-glass token. **`manifests/00-namespaces-and-groups`** are the bootstrap groups (IdP-synced in production).
8. **`manifests/01-audit`** turns on `WriteRequestBodies` and forwards audit events to Splunk and LokiStack from one pipeline. **`manifests/05-alerting/loki-alertingrules-audit.yaml`** matches on the flattened field names (`annotations_guardrails_critical_delete_decision`, `..._validation_failure`), **`prometheusrule-gitops-health.yaml`** is the audit-independent second pipeline, and **`alertmanager-main.yaml`** routes `guardrail="true"` to email + Teams with `group_wait: 0s`.
9. **`manifests/04-argocd`**: the ArgoCD CR patch (SSO, RBAC deny delete/override, server-side diff via controller env), the fenced AppProject (destinations must list every namespace the base renders into), and the app-of-apps with no cascade finalizer, `prune: true` (Git is the source of truth) and `selfHeal`.
10. **`scripts/lib.sh`** holds the annotation contract used by the four workflow scripts; `scripts/test-guardrails.sh` encodes the expected allow/deny of every rule, reading each binding's live `validationActions` so the same script is correct in every phase.
11. **`html/`** is the published site (`.github/workflows/static.yml` deploys `./html` to GitHub Pages on every push to `main`, https://a2z-ice.github.io/openshift-gaurdtail/). `html/index.html` and `html/study-guide.html` are hand-written; `html/docs/*.html` are generated from `README.md` and `docs/*.md` by `scripts/build-html-docs.mjs`, and CI fails if they are stale.

Invariants that span files and must be kept in sync when one changes: the four annotation keys `delete-request`, `-requested-by`, `-requested-at`, `-approvals` (policy ↔ `scripts/lib.sh` ↔ reaper ConfigMap ↔ Argo CD `ignoreDifferences`; CI checks), the tracker's `nameCritical`/`matchConstraints` ↔ `vap-critical-delete.yaml` (CI checks), `requestTTL`/`approvalTTL` ↔ the reminder windows in `loki-alertingrules-audit.yaml` (CI checks), the policy names (↔ Loki rule field names, which derive from the policy name not the prefix), the V1–V4 rule table in `docs/04`, the facts table in `AGENTS.md` and `llm/context.yaml`, the traceability matrix in `docs/16`, the `resourceNames` lists in `02-rbac/clusterroles.yaml` (↔ every guardrails-* object name), the AppProject destinations (↔ every namespace the base renders into), the identity markers (`humanAuthExtraKey` / bound-token credential-id in `GuardrailConfig` ↔ every policy's `boundToken`/`humanMarker` variables ↔ `HUMAN_EXTRA`/`SA_EXTRA` in the test script), and any Markdown doc ↔ its generated `html/docs` page (regenerate) ↔ the hand-written study guide and portal (update by hand when a fact changes).

## Repository quirks

- Overlays must reference `../../base`, never `../../` (kustomize detects a cycle because `manifests/` contains the overlays).
- `.yamllint` allows one space inside braces/brackets (the compact `{ type: string }` style is used throughout); do not "fix" the style.
- Scripts must stay bash-3.2 compatible (macOS): expand possibly-empty arrays as `${ARR[@]+"${ARR[@]}"}`; read annotations with `{{with index . "key"}}{{.}}{{end}}` (a bare `index` prints `<no value>`).
- The two Node tools need their packages installed in the repo root first (`npm i --no-save mermaid@11 jsdom dompurify marked`; `node_modules/` is git-ignored).
- CEL lives in YAML block scalars (`>-`), where a stray trailing `"` is valid YAML but a CEL compile error at the API server; CI's CEL literal/bracket check is the gate (two such defects shipped before it existed, docs/19 §9).
- Mermaid diagrams must use double-quoted labels with no parentheses, semicolons, quotes or `&`; GitHub silently renders a broken block as text. `scripts/check-mermaid.mjs` is the gate.
- Placeholders (`guardrails.example.com`, `example-org`, `REPLACE_*`) are intentional; the replacement procedure is `docs/00-placeholders.md`.
- Secrets manifests (`alertmanager-main.yaml`, `loki-s3-secret.example.yaml`) are deliberately excluded from kustomizations; they are rendered from the vault.
- `docs/14-manual-test-guide.md` T-numbers and `scripts/test-guardrails.sh` cases describe the same scenarios; update both and the matrix in `docs/16`.
