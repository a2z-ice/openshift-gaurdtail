---
name: guardrail-incident
description: Respond to a guardrail alert (CriticalResourceDeleted, GitOpsResourceDeleted, CriticalResourceDeleteDenied, GuardrailPolicyModified, AuditProfileChanged, PrivilegedRBACChange, ImpersonationUsed, BreakGlassUsed, ArgoCD*Missing, GitOpsNamespaceTerminating, AuditLogIngestionStalled). Use when an alert text or Teams card is pasted or when asked what to do about a red alert.
---

# Incident response

1. **Acknowledge** in Teams (≤ 5 min). Note alert name, object (`objectRef_*`), actor (`user_username`, `impersonatedUser_username`), time.
2. **Attribute**: run the `guardrail-investigate` skill on the object. Decide:
   | Finding | Classification |
   |---|---|
   | `approved=true`, valid change ticket | expected; close with ticket reference |
   | `gitops=true` (GitOpsCriticalDeletionApplied) with a merged PR that removed the object | expected GitOps path; link the PR. No PR → controller identity compromised: treat as CriticalResourceDeleted + PrivilegedTokenMinted check |
   | `exempt=true` (break-glass) with open incident naming two custodians | expected; verify commands match the incident |
   | `exempt=true` without incident, or impersonation, or `kube:admin`/`system:admin` | **security incident**: revoke tokens (`oc delete useroauthaccesstokens --field-selector=userName=<user>`), remove from IdP groups, page security |
   | delete of a GitOps object with **no** `decision` annotation | policy did not evaluate → check `GuardrailPolicyModified` history and `oc get vapb` immediately |
3. **Contain / restore** by alert:
   - `CriticalResourceDeleted` / `ArgoCD*Missing` / `GitOpsNamespaceTerminating`: `docs/09-runbooks.md` §Restore Argo CD (`oc apply --server-side -k manifests/overlays/<phase>` if operator present; reinstall operator first if not; secrets via OADP restore or ESO). RTO 10–30 min.
   - `GuardrailPolicyModified` / `AuditProfileChanged` / `AuditForwarderChanged`: `argocd app sync guardrails`; `argocd app diff guardrails`; re-run smoke test (delete dry-run must be denied).
   - `CriticalResourceDeleteDenied`: no damage; identify who/why (often Argo CD after a manifest was removed from Git → review the PR).
   - `AuditLogIngestionStalled` / `LokiRulerDown`: check forwarder/LokiStack conditions and pods in `openshift-logging`; detection is blind meanwhile, watch the SIEM directly.
   - `PrivilegedRBACChange`: match to an access-request ticket or revert via PR.
   - `ImpersonatedWriteDenied` / `PrivilegedIdentityImpersonated`: a non-dry-run write under `--as`; revoke the actor's OAuth tokens, remove JIT membership, incident (`docs/17`).
4. **Verify** with `scripts/verify-install.sh`.
5. **Post-mortem** within 5 working days using the template in `docs/09-runbooks.md`; update `docs/01` residual-risk register and `llm/memory.md`.
