---
name: guardrail-delete
description: Request, approve, execute or cancel the deletion of a critical OpenShift resource under the two-person rule (Argo CD, namespaces, CRDs, policies, anything labelled guardrails.example.com/critical=true). Use when the user says delete, remove, decommission, approve deletion, or asks why a delete was denied.
---

# Critical-resource deletion (two-person rule)

Three different humans are required: requester, two approvers (in `gitops-deletion-approvers`, not the requester), executor (not an approver). The admission policy enforces this; the scripts only make it convenient.

## Procedure

1. Confirm a change ticket exists and the target: `<resource> <name> [-n <ns>]`. Confirm the caller's role: `oc whoami` and `oc get group gitops-deletion-approvers -o jsonpath='{.users}'`.
2. **Requester**: `scripts/request-deletion.sh <res> <name> [-n ns] "CHG…: <reason>"` (sets request + requested-by, clears approvals).
3. **Approver 1, then approver 2** (each from their own login): `scripts/approve-deletion.sh <res> <name> [-n ns]` and type `approve`.
4. **Executor**, within 4h: `scripts/execute-deletion.sh <res> <name> [-n ns]`. A red `CriticalResourceDeleted` alert to email + Teams is expected; acknowledge it with the ticket.
5. If Argo CD manages the object, merge the PR that removes it from Git in the same window, or self-heal recreates it.
6. Append a line to `llm/memory.md` §State log.

Cancel any time: `scripts/cancel-deletion.sh <res> <name> [-n ns]`.

## If denied

Read the `GUARDRAIL DENIED:` message; it names the missing condition. Check state:
`oc get <res> <name> [-n ns] -o jsonpath='{.metadata.annotations}' | tr ',' '\n' | grep guardrails`
Typical causes: one approval only; approver == requester; executor is an approver; approvals expired (reaper) → re-approve; reason edited after approvals (wipes them); approver not in the group (IdP sync lag).

## Never

Do not propose `--as`, `kubeadmin`, `system:admin`, the break-glass token, finalizer patches, or editing `validationActions`/`exemptUsers`. All are P1 alerts by design. Break-glass is only for unreachable approvers; see `docs/09-runbooks.md` §Break-glass.
