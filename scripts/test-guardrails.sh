#!/usr/bin/env bash
# End-to-end test matrix for the deletion guardrail. Safe to run on a live cluster: it only touches
# a scratch namespace it creates (guardrails-test) plus DRY-RUN deletes against real critical objects.
#
# Two ways to act as different identities:
#   IMPERSONATE=true   (default) uses `oc --as=<user> --as-group=<group>` from a cluster-admin session.
#                      NOTE: impersonation itself raises ImpersonationUsed (expected during the test window).
#   IMPERSONATE=false  expects KUBECONFIG_REQUESTER / KUBECONFIG_APPROVER1 / KUBECONFIG_APPROVER2 / KUBECONFIG_EXECUTOR
#                      pointing at real logins (the realistic, alert-free way; use for the sign-off run).
#
# Each case prints PASS/FAIL with the expected vs actual outcome. Evidence is written to ./evidence-<timestamp>.log
set -uo pipefail
IMPERSONATE="${IMPERSONATE:-true}"
NS=guardrails-test
REQ_USER="${REQ_USER:-requester.test@example.com}"
APP1="${APP1:-approver1.test@example.com}"
APP2="${APP2:-approver2.test@example.com}"
EXEC_USER="${EXEC_USER:-executor.test@example.com}"
APPROVER_GROUP=gitops-deletion-approvers
REQUESTER_GROUP=gitops-deletion-requesters
LOG="evidence-$(date -u +%Y%m%dT%H%M%SZ).log"
PASS=0; FAIL=0
PFX="guardrails.example.com"

as() { # as <role> -- <oc args>
  local role="$1"; shift; shift
  if [[ "$IMPERSONATE" == "true" ]]; then
    case "$role" in
      requester) oc --as="$REQ_USER"  --as-group="$REQUESTER_GROUP" --as-group=system:authenticated "$@" ;;
      approver1) oc --as="$APP1"      --as-group="$APPROVER_GROUP"  --as-group=system:authenticated "$@" ;;
      approver2) oc --as="$APP2"      --as-group="$APPROVER_GROUP"  --as-group=system:authenticated "$@" ;;
      executor)  oc --as="$EXEC_USER" --as-group="$REQUESTER_GROUP" --as-group=system:authenticated "$@" ;;
      admin)     oc "$@" ;;
    esac
  else
    case "$role" in
      requester) KUBECONFIG="$KUBECONFIG_REQUESTER" oc "$@" ;;
      approver1) KUBECONFIG="$KUBECONFIG_APPROVER1" oc "$@" ;;
      approver2) KUBECONFIG="$KUBECONFIG_APPROVER2" oc "$@" ;;
      executor)  KUBECONFIG="$KUBECONFIG_EXECUTOR"  oc "$@" ;;
      admin)     oc "$@" ;;
    esac
  fi
}
expect() { # expect <deny|allow> <description> -- <command...>
  local want="$1" desc="$2"; shift 3
  local out rc
  out="$("$@" 2>&1)"; rc=$?
  local got="allow"; [[ $rc -ne 0 ]] && got="deny"
  if [[ "$got" == "$want" ]]; then PASS=$((PASS+1)); printf '  \033[1;32mPASS\033[0m %-70s (%s)\n' "$desc" "$got"
  else FAIL=$((FAIL+1)); printf '  \033[1;31mFAIL\033[0m %-70s (wanted %s, got %s)\n' "$desc" "$want" "$got"; fi
  { echo "### $desc"; echo "want=$want got=$got rc=$rc"; echo "$out"; echo; } >> "$LOG"
}
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

echo "Evidence -> $LOG"
echo "== 0. scratch objects"
oc create ns $NS --dry-run=client -o yaml | oc apply -f - >/dev/null
oc -n $NS create configmap victim --from-literal=a=b --dry-run=client -o yaml | oc apply -f - >/dev/null
oc -n $NS label configmap victim $PFX/critical=true --overwrite >/dev/null
oc -n $NS create configmap bystander --from-literal=a=b --dry-run=client -o yaml | oc apply -f - >/dev/null

echo "== 1. baseline: non-critical objects are untouched"
expect allow "delete a non-critical configmap"                 -- as admin -- -n $NS delete configmap bystander

echo "== 2. no single identity can delete a critical object"
expect deny  "cluster-admin deletes critical configmap"        -- as admin -- -n $NS delete configmap victim
expect deny  "cluster-admin removes the critical label"        -- as admin -- -n $NS label configmap victim $PFX/critical-
expect deny  "cluster-admin dry-run delete ArgoCD CR"          -- as admin -- -n openshift-gitops delete argocd openshift-gitops --dry-run=server
expect deny  "cluster-admin dry-run delete openshift-gitops ns" -- as admin -- delete ns openshift-gitops --dry-run=server
expect deny  "cluster-admin dry-run delete applications CRD"   -- as admin -- delete crd applications.argoproj.io --dry-run=server
expect deny  "cluster-admin dry-run delete GuardrailConfig"    -- as admin -- delete guardrailconfig default --dry-run=server
expect deny  "cluster-admin dry-run delete policy binding"     -- as admin -- delete validatingadmissionpolicybinding guardrails-critical-delete-named --dry-run=server
expect deny  "cluster-admin dry-run delete approver group"     -- as admin -- delete group $APPROVER_GROUP --dry-run=server

echo "== 2b. only trusted identities may mark an object critical"
oc -n $NS create configmap tenant --from-literal=a=b --dry-run=client -o yaml | oc apply -f - >/dev/null
expect deny  "requester (not approver) labels an object critical"   -- as requester -- -n $NS label configmap tenant $PFX/critical=true
expect allow "approver labels an object critical"                   -- as approver1 -- -n $NS label configmap tenant $PFX/critical=true

echo "== 3. forged approvals are rejected"
expect deny  "admin writes 2 approvals directly"               -- as admin -- -n $NS annotate configmap victim --overwrite "$PFX/delete-approvals=$APP1|$(ts),$APP2|$(ts)"
expect deny  "requester sets requested-by to someone else"     -- as requester -- -n $NS annotate configmap victim --overwrite "$PFX/delete-request=CHG1: test" "$PFX/delete-requested-by=$APP1"
expect deny  "approver approves before any request exists"     -- as approver1 -- -n $NS annotate configmap victim --overwrite "$PFX/delete-approvals=$APP1|$(ts)"

echo "== 4. the happy path"
expect allow "requester opens a request"                       -- as requester -- -n $NS annotate configmap victim --overwrite "$PFX/delete-request=CHG1: guardrail test" "$PFX/delete-requested-by=$REQ_USER"
expect deny  "requester approves own request"                  -- as requester -- -n $NS annotate configmap victim --overwrite "$PFX/delete-approvals=$REQ_USER|$(ts)"
expect deny  "approver1 approves under a different name"       -- as approver1 -- -n $NS annotate configmap victim --overwrite "$PFX/delete-approvals=$APP2|$(ts)"
expect deny  "approver1 approves AND changes data in one shot" -- as approver1 -- -n $NS patch configmap victim --type merge -p "{\"metadata\":{\"annotations\":{\"$PFX/delete-approvals\":\"$APP1|$(ts)\"}},\"data\":{\"a\":\"hacked\"}}"
expect allow "approver1 approves"                              -- as approver1 -- -n $NS annotate configmap victim --overwrite "$PFX/delete-approvals=$APP1|$(ts)"
expect deny  "executor deletes with only 1 approval"           -- as executor -- -n $NS delete configmap victim
expect deny  "approver1 approves a second time"                -- as approver1 -- -n $NS annotate configmap victim --overwrite "$PFX/delete-approvals=$APP1|$(ts),$APP1|$(ts)"
CUR="$(oc -n $NS get configmap victim -o go-template="{{index .metadata.annotations \"$PFX/delete-approvals\"}}")"
expect deny  "approver2 tries to drop approver1 while approving" -- as approver2 -- -n $NS annotate configmap victim --overwrite "$PFX/delete-approvals=$APP2|$(ts)"
expect allow "approver2 approves"                              -- as approver2 -- -n $NS annotate configmap victim --overwrite "$PFX/delete-approvals=$CUR,$APP2|$(ts)"
expect deny  "approver1 (an approver) executes the delete"     -- as approver1 -- -n $NS delete configmap victim
expect deny  "requester changes the reason after approvals"    -- as requester -- -n $NS annotate configmap victim --overwrite "$PFX/delete-request=CHG1: changed"
expect allow "executor deletes with 2 approvals"               -- as executor -- -n $NS delete configmap victim

echo "== 5. cancel path"
oc -n $NS create configmap victim2 --from-literal=a=b --dry-run=client -o yaml | oc apply -f - >/dev/null
oc -n $NS label configmap victim2 $PFX/critical=true --overwrite >/dev/null
expect allow "requester opens request on victim2"              -- as requester -- -n $NS annotate configmap victim2 --overwrite "$PFX/delete-request=CHG2: cancel test" "$PFX/delete-requested-by=$REQ_USER"
expect allow "approver1 approves victim2"                      -- as approver1 -- -n $NS annotate configmap victim2 --overwrite "$PFX/delete-approvals=$APP1|$(ts)"
expect allow "anyone cancels (clears all guardrail annotations)" -- as approver2 -- -n $NS annotate configmap victim2 --overwrite "$PFX/delete-request-" "$PFX/delete-requested-by-" "$PFX/delete-approvals-"
expect deny  "delete after cancel"                             -- as executor -- -n $NS delete configmap victim2

echo "== 6. reaper only removes"
oc -n $NS annotate configmap victim2 --overwrite "$PFX/delete-request=CHG3: reaper" "$PFX/delete-requested-by=$REQ_USER" >/dev/null 2>&1 || true
OLD="$APP1|2000-01-01T00:00:00Z"
as approver1 -- -n $NS annotate configmap victim2 --overwrite "$PFX/delete-approvals=$APP1|$(ts)" >/dev/null 2>&1 || true
expect deny  "reaper SA tries to ADD an approval"              -- oc --as=system:serviceaccount:guardrails-system:approval-reaper -n $NS annotate configmap victim2 --overwrite "$PFX/delete-approvals=$(oc -n $NS get cm victim2 -o go-template="{{index .metadata.annotations \"$PFX/delete-approvals\"}}"),$APP2|$(ts)"
expect allow "reaper SA removes all approvals"                 -- oc --as=system:serviceaccount:guardrails-system:approval-reaper -n $NS annotate configmap victim2 --overwrite "$PFX/delete-approvals-"

echo "== 7. cleanup (scratch namespace is not critical)"
oc -n $NS annotate configmap victim2 --overwrite "$PFX/delete-request-" "$PFX/delete-requested-by-" "$PFX/delete-approvals-" >/dev/null 2>&1 || true
oc -n $NS label configmap victim2 $PFX/critical- >/dev/null 2>&1 || true   # denied while critical: that is expected; delete the namespace instead
oc delete ns $NS --wait=false >/dev/null 2>&1 || true

echo; echo "PASS=$PASS FAIL=$FAIL  (evidence: $LOG)"
echo "Now confirm in Teams/email: CriticalResourceDeleted for configmap $NS/victim, CriticalResourceDeleteDenied for the blocked attempts, ImpersonationUsed if IMPERSONATE=true."
[[ $FAIL -eq 0 ]]
