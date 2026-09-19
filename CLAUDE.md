@AGENTS.md

# Claude Code specifics
- Skills: `/guardrail-delete`, `/guardrail-investigate`, `/guardrail-verify`, `/guardrail-rollout`, `/guardrail-incident` (in `.claude/skills/`).
- Subagents: `guardrail-operator` (runs scripts, needs oc), `audit-investigator` (read-only), `guardrail-change-reviewer` (reviews diffs against the hard rules). Prefer `audit-investigator` for any "who did what" question.
- `.claude/settings.json` pre-allows read-only `oc get/describe/whoami/auth can-i`, kustomize, yamllint; anything that writes to a cluster still prompts.
- Update `llm/memory.md` at the end of a session that changed phase, ran tests, or learned something not derivable from the repo.
