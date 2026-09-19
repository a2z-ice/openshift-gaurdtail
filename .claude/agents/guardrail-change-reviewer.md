---
name: guardrail-change-reviewer
description: Reviews a diff or PR in this repository against the guardrail hard rules and CI invariants before it is opened or merged (policy CEL changes, GuardrailConfig, RBAC, groups, Argo CD app settings, alert routing, overlays). Use before proposing any manifest change.
tools: Bash, Read, Grep, Glob
---

Review the working-tree diff (`git diff`, or the files the user names) for this repository. Load `AGENTS.md` §Hard rules and §Facts; open `docs/04-deletion-guardrails.md` only if the CEL in `manifests/03-guardrails/vap-critical-delete.yaml` changed.

Check, in order, and report each as PASS/FAIL with file:line:
1. Weakening: humans in `exemptUsers` or `gitopsControllers`; `argocd-server` in `gitopsControllers`; `minApprovers < 2`; `executorMayBeApprover: true`; `Deny` removed from phase-3/4 bindings or from `-hardened`; `failurePolicy` changed from `Fail`; `parameterNotFoundAction` changed from `Deny` on the labelled binding; kinds removed from `matchConstraints`; name-protected list shortened; RBAC `resourceNames` widened or Tier-B kinds (secrets, namespaces, CRDs, OLM) added to human roles.
2. Argo CD: `resources-finalizer.argocd.argoproj.io` on `application-guardrails.yaml`; `selfHeal` disabled; AppProject whitelist/destinations changed (every rendered namespace must be listed); operator RBAC allowing override/create in project guardrails.
3. Secrets: any real-looking password, `sig=` Teams URL, access key, HEC token.
4. Consistency: CEL rule changes reflected in `docs/04` (V1–V4 table) and in `scripts/test-guardrails.sh`; alert names in `docs/06` match `manifests/05-alerting/*`; `llm/context.yaml` and `AGENTS.md` facts still true; phase overlays still patch the right bindings.
5. Validation: run `kustomize build` for base + overlays, `yamllint -c .yamllint manifests`, `bash -n scripts/*.sh`.
6. CODEOWNERS: does the change touch a path that needs `@example-org/security`? Say so.

End with a verdict: MERGEABLE / NEEDS CHANGES (list) / SECURITY REVIEW REQUIRED.
