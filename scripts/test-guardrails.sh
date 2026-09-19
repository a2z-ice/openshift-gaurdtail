#!/usr/bin/env bash
# End-to-end test matrix for the deletion guardrail. Safe on a live cluster: it only touches a scratch
# namespace it creates (guardrails-test) plus DRY-RUN deletes against real critical objects.
#
# Identity modes
#   IMPERSONATE=true  (default) uses `oc --as=<user> --as-group=<group>` from a cluster-admin session.
#                     Impersonation raises ImpersonationUsed on purpose (expected during a test window).
#   IMPERSONATE=false uses KUBECONFIG_REQUESTER / KUBECONFIG_APPROVER1 / KUBECONFIG_APPROVER2 / KUBECONFIG_EXECUTOR
#                     (real logins: the alert-free sign-off run). Cases that need a service-account identity are
#                     run through a Job instead of impersonation in this mode.
#
# Phase awareness: the expected outcome of every case is derived from the live validationActions of the
# bindings, so the script is correct in phase 1 (nothing blocked; evidence = audit annotations), phase 2 (warnings)
# and phases 3/4 (denials). Evidence: ./evidence/<timestamp>.log (override with EVIDENCE_DIR).
set -uo pipefail
IMPERSONATE="${IMPERSONATE:-true}"
NS=guardrails-test
REQ_USER="${REQ_USER:-requester.test@example.com}"
APP1="${APP1:-approver1.test@example.com}"
APP2="${APP2:-approver2.test@example.com}"
EXEC_USER="${EXEC_USER:-executor.test@example.com}"
DEV_USER="${DEV_USER:-developer.test@example.com}"
APPROVER_GROUP=gitops-deletion-approvers
REQUESTER_GROUP=gitops-deletion-requesters
PFX="guardrails.example.com"
EVIDENCE_DIR="${EVIDENCE_DIR:-./evidence}"; mkdir -p "$EVIDENCE_DIR"
LOG="$EVIDENCE_DIR/$(date -u +%Y%m%dT%H%M%SZ).log"
PASS=0; FAIL=0; SKIP=0

# ---- phase detection ------------------------------------------------------------------------------------
actions() { oc get validatingadmissionpolicybinding "$1" -o jsonpath='{.spec.validationActions}' 2>/dev/null; }
DELETE_ACTIONS="$(actions guardrails-critical-delete-labelled)"
MUTATION_ACTIONS="$(actions guardrails-gitops-only-mutation)"
LABEL_ACTIONS="$(actions guardrails-critical-label-control)"
enforced() { [[ "$1" == *Deny* ]]; }
# expectation for a "should be denied" case, given a binding's actions
want_deny() { if enforced "$1"; then echo deny; else echo allow; fi; }
DENY_DEL="$(want_deny "$DELETE_ACTIONS")"; DENY_MUT="$(want_deny "$MUTATION_ACTIONS")"; DENY_LBL="$(want_deny "$LABEL_ACTIONS")"
echo "Bindings: delete=$DELETE_ACTIONS  label-control=$LABEL_ACTIONS  gitops-only=$MUTATION_ACTIONS (hardened binding is always Deny)"
echo "Evidence -> $LOG"

# ---- identities ------------------------------------------------------------------------------------------
as() { # as <role> -- <oc args>
  local role="$1"; shift; shift
  if [[ "$IMPERSONATE" == "true" ]]; then
    case "$role" in
      requester) oc --as="$REQ_USER"  --as-group="$REQUESTER_GROUP" --as-group=system:authenticated "$@" ;;
      approver1) oc --as="$APP1"      --as-group="$APPROVER_GROUP"  --as-group=system:authenticated "$@" ;;
      approver2) oc --as="$APP2"      --as-group="$APPROVER_GROUP"  --as-group=system:authenticated "$@" ;;
      executor)  oc --as="$EXEC_USER" --as-group="$REQUESTER_GROUP" --as-group=system:authenticated "$@" ;;
      approver1-executor) oc --as="$APP1" --as-group="$APPROVER_GROUP" --as-group="$REQUESTER_GROUP" --as-group=system:authenticated "$@" ;;
      developer) oc --as="$DEV_USER"  --as-group=system:authenticated "$@" ;;
      admin)     oc "$@" ;;
    esac
  else
    case "$role" in
      requester) KUBECONFIG="$KUBECONFIG_REQUESTER" oc "$@" ;;
      approver1) KUBECONFIG="$KUBECONFIG_APPROVER1" oc "$@" ;;
      approver2) KUBECONFIG="$KUBECONFIG_APPROVER2" oc "$@" ;;
      executor)  KUBECONFIG="$KUBECONFIG_EXECUTOR"  oc "$@" ;;
      approver1-executor) KUBECONFIG="${KUBECONFIG_APPROVER_EXECUTOR:-$KUBECONFIG_APPROVER1}" oc "$@" ;;
      developer) KUBECONFIG="${KUBECONFIG_DEVELOPER:-$KUBECONFIG_REQUESTER}" oc "$@" ;;
      admin)     oc "$@" ;;
    esac
  fi
}
record() { { echo "### $1"; echo "want=$2 got=$3 rc=$4"; echo "$5"; echo; } >> "$LOG"; }
expect() { # expect <deny|allow|skip> <description> -- <command...>
  local want="$1" desc="$2"; shift 3
  if [[ "$want" == "skip" ]]; then SKIP=$((SKIP+1)); printf '  \033[1;33mSKIP\033[0m %s\n' "$desc"; return; fi
  local out rc; out="$("$@" 2>&1)"; rc=$?
  local got="allow"; [[ $rc -ne 0 ]] && got="deny"
  if [[ "$got" == "$want" ]]; then PASS=$((PASS+1)); printf '  \033[1;32mPASS\033[0m %-72s (%s)\n' "$desc" "$got"
  else FAIL=$((FAIL+1)); printf '  \033[1;31mFAIL\033[0m %-72s (wanted %s, got %s)\n' "$desc" "$want" "$got"; fi
  record "$desc" "$want" "$got" "$rc" "$out"
}
expect_warn() { # expect_warn <description> <pattern> -- <command...>: request must SUCCEED and print a Warning matching pattern
  local desc="$1" pat="$2"; shift 3
  local out rc; out="$("$@" 2>&1)"; rc=$?
  if [[ $rc -eq 0 && "$out" == *"$pat"* ]]; then PASS=$((PASS+1)); printf '  \033[1;32mPASS\033[0m %-72s (warned)\n' "$desc"
  else FAIL=$((FAIL+1)); printf '  \033[1;31mFAIL\033[0m %-72s (rc=%s, warning %s)\n' "$desc" "$rc" "$([[ "$out" == *"$pat"* ]] && echo present || echo missing)"; fi
  record "$desc" "warn" "rc=$rc" "$rc" "$out"
}
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
approvals_of() { oc -n "$NS" get cm "$1" -o go-template="{{with .metadata.annotations}}{{with index . \"$PFX/delete-approvals\"}}{{.}}{{end}}{{end}}"; }
mk_cm() { oc -n "$NS" create configmap "$1" --from-literal=a=b --dry-run=client -o yaml | oc apply -f - >/dev/null; }
# full workflow on a scratch object (used for cleanup and the happy path); all steps are asserted
workflow_delete() { # workflow_delete <cm>
  expect allow "requester opens request on $1"      -- as requester -- -n "$NS" annotate configmap "$1" --overwrite "$PFX/delete-request=CHG-cleanup: $1" "$PFX/delete-requested-by=$REQ_USER" "$PFX/delete-approvals-"
  expect allow "approver1 approves $1"              -- as approver1 -- -n "$NS" annotate configmap "$1" --overwrite "$PFX/delete-approvals=$APP1|$(ts)"
  expect allow "approver2 approves $1"              -- as approver2 -- -n "$NS" annotate configmap "$1" --overwrite "$PFX/delete-approvals=$(approvals_of "$1"),$APP2|$(ts)"
  expect allow "executor deletes $1 with 2 approvals" -- as executor -- -n "$NS" delete configmap "$1"
}

# ---- 0. scratch namespace + RoleBindings (the workflow roles are namespaced; the test namespace needs its own) ----
if [[ "$(oc get ns "$NS" -o jsonpath='{.status.phase}' 2>/dev/null)" == "Terminating" ]]; then
  echo "namespace $NS is Terminating from a previous run; finish its critical objects through the workflow first"; exit 2
fi
oc create ns "$NS" --dry-run=client -o yaml | oc apply -f - >/dev/null
for rb in approver:guardrails-approver-namespaced:$APPROVER_GROUP approver-req:guardrails-approver-namespaced:$REQUESTER_GROUP executor:guardrails-executor-namespaced:$REQUESTER_GROUP; do
  IFS=: read -r n role grp <<< "$rb"
  oc -n "$NS" create rolebinding "test-$n" --clusterrole="$role" --group="$grp" --dry-run=client -o yaml | oc apply -f - >/dev/null
done
# the namespaced approver role limits configmap patch to named reaper/sync maps; the scratch objects need their own Role
oc -n "$NS" apply -f - >/dev/null <<YAML
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: { name: test-scratch-configmaps }
rules:
  - apiGroups: [""]
    resources: ["configmaps"]
    verbs: ["get", "list", "patch", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: { name: test-scratch-configmaps }
roleRef: { apiGroup: rbac.authorization.k8s.io, kind: Role, name: test-scratch-configmaps }
subjects:
  - { kind: Group, apiGroup: rbac.authorization.k8s.io, name: $APPROVER_GROUP }
  - { kind: Group, apiGroup: rbac.authorization.k8s.io, name: $REQUESTER_GROUP }
YAML
mk_cm victim; mk_cm bystander; mk_cm tenant

echo "== 1. label control: only trusted identities may mark an object critical"
expect "$DENY_LBL" "requester (not approver) labels an object critical"          -- as requester -- -n "$NS" label configmap tenant "$PFX/critical=true"
expect "$DENY_LBL" "cluster-admin (not approver) labels an object critical"      -- as admin     -- -n "$NS" label configmap victim "$PFX/critical=true"
expect allow       "approver labels victim critical"                              -- as approver1 -- -n "$NS" label configmap victim "$PFX/critical=true" --overwrite
expect "$DENY_LBL" "developer CREATES an object already labelled critical"        -- as developer -- -n "$NS" create configmap precreated --from-literal=a=b --dry-run=server
# in phases 1-2 the two label writes above succeeded; normalise so later cases start from a known state
oc -n "$NS" label configmap victim "$PFX/critical=true" --overwrite >/dev/null 2>&1 || true
if [[ "$DENY_LBL" == "allow" ]]; then oc -n "$NS" label configmap tenant "$PFX/critical-" >/dev/null 2>&1 || true; fi

echo "== 2. baseline: non-critical objects untouched; RBAC least privilege"
expect allow       "delete a non-critical configmap"                              -- as admin     -- -n "$NS" delete configmap bystander
expect deny        "approver cannot read a Secret in openshift-gitops (RBAC)"     -- as approver1 -- -n openshift-gitops get secret openshift-gitops-cluster
expect deny        "requester cannot delete a non-critical namespace (RBAC)"      -- as executor  -- delete namespace "$NS" --dry-run=server
expect deny        "approver cannot list secrets cluster-wide (RBAC)"             -- as approver1 -- get secrets -A
expect deny        "approver cannot delete an Application (RBAC)"                 -- as approver1 -- -n openshift-gitops delete application guardrails --dry-run=server

echo "== 3. no single identity can delete or unlabel a critical object"
expect "$DENY_DEL" "cluster-admin deletes critical configmap"                     -- as admin -- -n "$NS" delete configmap victim
expect "$DENY_DEL" "cluster-admin removes the critical label"                     -- as admin -- -n "$NS" label configmap victim "$PFX/critical-"
expect "$DENY_DEL" "cluster-admin deletes by label selector (deletecollection)"   -- as admin -- -n "$NS" delete configmap -l "$PFX/critical=true"
expect "$DENY_DEL" "cluster-admin dry-run delete ArgoCD CR"                       -- as admin -- -n openshift-gitops delete argocd openshift-gitops --dry-run=server
expect "$DENY_DEL" "cluster-admin dry-run delete openshift-gitops namespace"      -- as admin -- delete ns openshift-gitops --dry-run=server
expect "$DENY_DEL" "cluster-admin dry-run delete applications CRD"                -- as admin -- delete crd applications.argoproj.io --dry-run=server
expect "$DENY_DEL" "cluster-admin dry-run delete GuardrailConfig"                 -- as admin -- delete guardrailconfig default --dry-run=server
expect "$DENY_DEL" "cluster-admin dry-run delete policy binding (R3)"             -- as admin -- delete validatingadmissionpolicybinding guardrails-critical-delete-named --dry-run=server
expect "$DENY_DEL" "cluster-admin dry-run delete approver group"                  -- as admin -- delete group "$APPROVER_GROUP" --dry-run=server
expect "$DENY_DEL" "cluster-admin dry-run delete guardrails ClusterRoleBinding"   -- as admin -- delete clusterrolebinding guardrails-approvers --dry-run=server
expect "$DENY_DEL" "cluster-admin dry-run delete GitOps operator Subscription"    -- as admin -- -n openshift-gitops-operator delete subscription openshift-gitops-operator --dry-run=server
expect "$DENY_DEL" "cluster-admin dry-run delete audit forwarder"                 -- as admin -- -n openshift-logging delete clusterlogforwarder audit-forwarder --dry-run=server
expect "$DENY_DEL" "cluster-admin dry-run delete guardrails Application"          -- as admin -- -n openshift-gitops delete application guardrails --dry-run=server

echo "== 4. self-protection set is GitOps-only in EVERY phase (hardened binding)"
expect deny        "cluster-admin patches binding validationActions"              -- as admin     -- patch validatingadmissionpolicybinding guardrails-critical-delete-labelled --type merge -p '{"spec":{"validationActions":["Audit"]}}' --dry-run=server
expect deny        "cluster-admin adds self to exemptUsers"                       -- as admin     -- patch guardrailconfig default --type merge -p '{"spec":{"exemptUsers":["system:apiserver","me@example.com"]}}' --dry-run=server
expect deny        "approver adds self to platform-admins group"                  -- as approver1 -- patch group platform-admins --type merge -p "{\"users\":[\"$APP1\"]}" --dry-run=server
expect deny        "approver changes reaper CronJob serviceAccount"               -- as approver1 -- -n guardrails-system patch cronjob approval-reaper --type merge -p '{"spec":{"jobTemplate":{"spec":{"template":{"spec":{"serviceAccountName":"breakglass"}}}}}}' --dry-run=server
expect allow       "approver may still annotate a self-protection object"         -- as approver1 -- annotate guardrailconfig default "$PFX/delete-request=CHG-test: rehearsal" "$PFX/delete-requested-by=$APP1" --overwrite --dry-run=server
expect "$DENY_MUT" "human edits spec of a critical object (gitops-only, phase 4 denies)" -- as admin -- -n "$NS" patch configmap victim --type merge -p '{"data":{"a":"hand-edited"}}' --dry-run=server

echo "== 5. forged approvals are rejected"
expect "$DENY_DEL" "admin writes 2 approvals directly"                            -- as admin     -- -n "$NS" annotate configmap victim --overwrite "$PFX/delete-approvals=$APP1|$(ts),$APP2|$(ts)"
expect "$DENY_DEL" "requester sets requested-by to someone else"                  -- as requester -- -n "$NS" annotate configmap victim --overwrite "$PFX/delete-request=CHG1: test" "$PFX/delete-requested-by=$APP1"
expect "$DENY_DEL" "developer (no requester group) opens a request"               -- as developer -- -n "$NS" annotate configmap victim --overwrite "$PFX/delete-request=CHG1: x" "$PFX/delete-requested-by=$DEV_USER"
expect "$DENY_DEL" "approver approves before any request exists"                  -- as approver1 -- -n "$NS" annotate configmap victim --overwrite "$PFX/delete-approvals=$APP1|$(ts)"
oc -n "$NS" annotate configmap victim --overwrite "$PFX/delete-request-" "$PFX/delete-requested-by-" "$PFX/delete-approvals-" >/dev/null 2>&1 || true   # phase 1/2: undo what succeeded

echo "== 6. the happy path, with every negative branch"
expect allow       "requester opens a request"                                    -- as requester -- -n "$NS" annotate configmap victim --overwrite "$PFX/delete-request=CHG1: guardrail test" "$PFX/delete-requested-by=$REQ_USER" "$PFX/delete-approvals-"
expect "$DENY_DEL" "requester approves own request"                               -- as requester -- -n "$NS" annotate configmap victim --overwrite "$PFX/delete-approvals=$REQ_USER|$(ts)"
expect "$DENY_DEL" "approver1 approves under a different name"                    -- as approver1 -- -n "$NS" annotate configmap victim --overwrite "$PFX/delete-approvals=$APP2|$(ts)"
expect "$DENY_DEL" "approver1 malformed entry (no timestamp)"                     -- as approver1 -- -n "$NS" annotate configmap victim --overwrite "$PFX/delete-approvals=$APP1"
expect "$DENY_DEL" "approver1 approves AND changes data in one patch"             -- as approver1 -- -n "$NS" patch configmap victim --type merge -p "{\"metadata\":{\"annotations\":{\"$PFX/delete-approvals\":\"$APP1|$(ts)\"}},\"data\":{\"a\":\"hacked\"}}"
oc -n "$NS" annotate configmap victim --overwrite "$PFX/delete-approvals-" >/dev/null 2>&1 || true
expect allow       "approver1 approves"                                           -- as approver1 -- -n "$NS" annotate configmap victim --overwrite "$PFX/delete-approvals=$APP1|$(ts)"
expect "$DENY_DEL" "executor deletes with only 1 approval"                        -- as executor  -- -n "$NS" delete configmap victim
expect "$DENY_DEL" "approver1 approves a second time"                             -- as approver1 -- -n "$NS" annotate configmap victim --overwrite "$PFX/delete-approvals=$(approvals_of victim),$APP1|$(ts)"
expect "$DENY_DEL" "approver2 replaces the list (drops approver1)"                -- as approver2 -- -n "$NS" annotate configmap victim --overwrite "$PFX/delete-approvals=$APP2|$(ts)"
if [[ "$DENY_DEL" == "allow" ]]; then oc -n "$NS" annotate configmap victim --overwrite "$PFX/delete-approvals=$APP1|$(ts)" >/dev/null 2>&1; fi   # phase 1/2 repair
expect allow       "approver2 appends"                                            -- as approver2 -- -n "$NS" annotate configmap victim --overwrite "$PFX/delete-approvals=$(approvals_of victim),$APP2|$(ts)"
expect "$DENY_DEL" "approver1 (an approver, also executor role) executes"         -- as approver1-executor -- -n "$NS" delete configmap victim
expect "$DENY_DEL" "requester changes the reason after approvals"                 -- as requester -- -n "$NS" annotate configmap victim --overwrite "$PFX/delete-request=CHG1: changed"
expect allow       "executor deletes with 2 approvals -> CriticalResourceDeleted" -- as executor  -- -n "$NS" delete configmap victim

echo "== 7. cancel path"
mk_cm victim2; as approver1 -- -n "$NS" label configmap victim2 "$PFX/critical=true" --overwrite >/dev/null
expect allow       "requester opens request on victim2"                           -- as requester -- -n "$NS" annotate configmap victim2 --overwrite "$PFX/delete-request=CHG2: cancel test" "$PFX/delete-requested-by=$REQ_USER"
expect allow       "approver1 approves victim2"                                   -- as approver1 -- -n "$NS" annotate configmap victim2 --overwrite "$PFX/delete-approvals=$APP1|$(ts)"
expect allow       "third party cancels (clears all guardrail annotations)"       -- as approver2 -- -n "$NS" annotate configmap victim2 --overwrite "$PFX/delete-request-" "$PFX/delete-requested-by-" "$PFX/delete-approvals-"
expect "$DENY_DEL" "delete after cancel"                                          -- as executor  -- -n "$NS" delete configmap victim2

echo "== 8. reaper: removes expired/future entries, cannot add"
expect allow       "requester opens request on victim2 (reaper test)"             -- as requester -- -n "$NS" annotate configmap victim2 --overwrite "$PFX/delete-request=CHG3: reaper" "$PFX/delete-requested-by=$REQ_USER" "$PFX/delete-approvals-"
expect allow       "approver1 approves with an EXPIRED timestamp"                 -- as approver1 -- -n "$NS" annotate configmap victim2 --overwrite "$PFX/delete-approvals=$APP1|2000-01-01T00:00:00Z"
expect allow       "approver2 approves with a FUTURE timestamp"                   -- as approver2 -- -n "$NS" annotate configmap victim2 --overwrite "$PFX/delete-approvals=$(approvals_of victim2),$APP2|2099-01-01T00:00:00Z"
JOB="reaper-test-$(date +%s)"
if oc -n guardrails-system create job "$JOB" --from=cronjob/approval-reaper >/dev/null 2>&1 && oc -n guardrails-system wait --for=condition=complete "job/$JOB" --timeout=180s >/dev/null 2>&1; then
  LEFT="$(approvals_of victim2)"
  if [[ -z "$LEFT" ]]; then PASS=$((PASS+1)); printf '  \033[1;32mPASS\033[0m %-72s\n' "reaper removed the expired and the future-dated approval"; else FAIL=$((FAIL+1)); printf '  \033[1;31mFAIL\033[0m %-72s (left: %s)\n' "reaper removed expired/future approvals" "$LEFT"; fi
  record "reaper run" "empty" "$LEFT" 0 "$(oc -n guardrails-system logs "job/$JOB" 2>&1)"
  oc -n guardrails-system delete job "$JOB" >/dev/null 2>&1 || true
else
  SKIP=$((SKIP+1)); printf '  \033[1;33mSKIP\033[0m %s\n' "reaper job could not be started/completed (check GuardrailReaperFailing)"
fi
if [[ "$IMPERSONATE" == "true" ]]; then
  expect "$DENY_DEL" "reaper SA tries to ADD an approval"                          -- oc --as=system:serviceaccount:guardrails-system:approval-reaper -n "$NS" annotate configmap victim2 --overwrite "$PFX/delete-approvals=$APP2|$(ts)"
else
  expect skip "reaper SA tries to ADD an approval (impersonation disabled)" -- true
fi

echo "== 9. the GitOps path is pre-approved: Argo CD controllers may delete/prune critical objects (Git ruleset is the approval)"
mk_cm gitmanaged; as approver1 -- -n "$NS" label configmap gitmanaged "$PFX/critical=true" --overwrite >/dev/null
if [[ "$IMPERSONATE" == "true" ]]; then
  expect allow "Argo CD application-controller identity deletes a critical object (GitOps path)" -- oc --as=system:serviceaccount:openshift-gitops:openshift-gitops-argocd-application-controller -n "$NS" delete configmap gitmanaged
  expect "$DENY_DEL" "argocd-server identity (UI/CLI, not Git) deletes a critical object"        -- oc --as=system:serviceaccount:openshift-gitops:openshift-gitops-argocd-server -n "$NS" delete configmap victim2 --dry-run=server
else
  expect skip "GitOps-path identity cases (impersonation disabled; covered by manual T7.1/T7.3)" -- true
  oc -n "$NS" delete configmap gitmanaged --ignore-not-found >/dev/null 2>&1 || true
fi

echo "== 10. rbac-escalation policy warns (never blocks) and stamps the audit event"
expect_warn "creating a cluster-admin binding is FLAGGED" "FLAGGED FOR AUDIT" -- as admin -- create clusterrolebinding guardrails-test-escalation --clusterrole=cluster-admin --user=nobody@example.com --dry-run=server

echo "== 11. cleanup through the workflow (proves the namespace is not left Terminating)"
oc -n "$NS" annotate configmap victim2 --overwrite "$PFX/delete-request-" "$PFX/delete-requested-by-" "$PFX/delete-approvals-" >/dev/null 2>&1 || true
workflow_delete victim2
if [[ "$(oc -n "$NS" get cm tenant -o jsonpath="{.metadata.labels.$(echo "$PFX" | sed 's/\./\\./g')/critical}" 2>/dev/null)" == "true" ]]; then workflow_delete tenant; fi
oc -n "$NS" delete configmap precreated gitmanaged --ignore-not-found >/dev/null 2>&1 || true
oc delete ns "$NS" --wait=false >/dev/null 2>&1 || true
sleep 5; PH="$(oc get ns "$NS" -o jsonpath='{.status.phase}' 2>/dev/null || echo Gone)"
echo "namespace $NS: ${PH}"

echo; echo "PASS=$PASS FAIL=$FAIL SKIP=$SKIP  (evidence: $LOG)"
echo "Now confirm delivery: CriticalResourceDeleted for configmap $NS/victim (email+Teams), GitOpsCriticalDeletionApplied for $NS/gitmanaged (Teams), CriticalResourceDeleteDenied (phase>=3) or CriticalDeleteWouldBeDenied (phase 1/2), PrivilegedRBACChange, ImpersonationUsed + PrivilegedIdentityImpersonated (impersonation mode)."
[[ $FAIL -eq 0 ]]
