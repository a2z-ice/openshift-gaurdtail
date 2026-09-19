---
name: guardrail-rollout
description: Move the guardrails between rollout phases (1 audit → 2 warn → 3 enforce → 4 gitops-only) or roll back, with exit criteria and the PR that changes the Argo CD application path. Use when asked to enable, enforce, promote, roll back or check readiness.
---

# Phase change

Phase = `spec.source.path` of Argo CD Application `openshift-gitops/guardrails` (`manifests/overlays/phase{1-audit,2-warn,3-enforce,4-gitops-only}`). Changing it is a PR with two approvals; never edit the live Application.

1. Determine current phase: `oc get application guardrails -n openshift-gitops -o jsonpath='{.spec.source.path}'` or `llm/memory.md`.
2. Check exit criteria of the current phase (`docs/10-rollout-plan.md`):
   - 1→2: VAP Ready, R3 answered, 7 days with zero unexplained would-have-been-denied events, all approvers rehearsed.
   - 2→3: 7 days with zero warnings from pipelines/operators, on-call acknowledged a synthetic red alert, `test-guardrails.sh` PASS on pre-prod, break-glass rehearsal ≤ 30 d, restore drill ≤ 90 d.
   - 3→4: 14 days with zero `ArgoCDDirectMutation`.
3. Open the PR: edit `manifests/overlays/<current>/kustomization.yaml` is NOT the way; instead change the Application in Git. Because each overlay patches its own path, the change is: in the overlay you are moving **to**, nothing; in `manifests/04-argocd/application-guardrails.yaml`, set `spec.source.path` to the new overlay. Run the local checks (`guardrail-verify`).
4. After merge, Argo CD applies it (bindings' `validationActions` change). Verify: `oc get vapb -l app.kubernetes.io/part-of=guardrails -o custom-columns=NAME:.metadata.name,ACTIONS:.spec.validationActions`, then the smoke test from `guardrail-verify`.
5. Rollback = the reverse PR. Emergency only: break-glass edits `validationActions` (P1 alert, incident, post-mortem).
6. Record `date | cluster | phase N→M | PR#` in `llm/memory.md` §State log.
