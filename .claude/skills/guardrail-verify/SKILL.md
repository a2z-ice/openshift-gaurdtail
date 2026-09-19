---
name: guardrail-verify
description: Validate this repository locally (kustomize, yamllint, shell syntax, CI invariants) and/or verify a live cluster's guardrail, audit, alerting and backup health. Use before proposing a PR, after an upgrade, or when asked "is the guardrail working".
---

# Verify

## Local (no cluster)
```bash
for o in manifests/base manifests/overlays/*; do kustomize build "$o" >/dev/null && echo "OK $o"; done
yamllint -c .yamllint manifests
bash -n scripts/*.sh
npm i --no-save mermaid@11 jsdom dompurify && node scripts/check-mermaid.mjs README.md docs/*.md   # diagrams render on GitHub
# CI invariants (same as .github/workflows/policy-ci.yaml)
grep -q '"Deny"' manifests/03-guardrails/vap-critical-delete-bindings.yaml
! grep -q 'resources-finalizer.argocd.argoproj.io' manifests/04-argocd/application-guardrails.yaml
! grep -Eq 'prune: *true' manifests/04-argocd/application-guardrails.yaml
! grep -A3 'exemptUsers:' manifests/03-guardrails/guardrailconfig-default.yaml | grep -E '^\s+- [^s].*@'
```
All must pass before a PR. Expected object count per overlay: 52.

## Cluster (needs oc login with a personal identity)
1. `scripts/verify-install.sh` — hard checks on policies (Ready), bindings' actions, kubeadmin removed, audit profile, forwarder Ready, Loki, alert rules, Alertmanager Teams route, Argo CD hardening, backups.
2. Smoke: `oc delete argocd openshift-gitops -n openshift-gitops --dry-run=server` → must be denied in phase ≥ 3 (phase 1/2: allowed, but the audit event carries `validation_failure`).
3. Policy status: `oc get vap guardrails-critical-delete -o jsonpath='{.status.conditions}'` — `Ready=True`; type-check *warnings* about undefined fields are expected, errors are not.
4. Full matrix (scratch namespace only): `scripts/test-guardrails.sh` → 30 cases; keep `evidence-*.log`. Impersonation mode raises `ImpersonationUsed` on purpose; use `IMPERSONATE=false` with four kubeconfigs for sign-off.
5. Alert delivery: `amtool alert add …` synthetic (command in `docs/06` §Teams) → Teams card + email ≤ 10 s.
6. Log the run in `llm/memory.md` §State log.
