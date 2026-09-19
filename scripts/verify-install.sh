#!/usr/bin/env bash
# Post-install health check for every layer. Exit code != 0 if a hard requirement is missing.
set -uo pipefail
FAIL=0
ok()   { printf '  \033[1;32mOK  \033[0m %s\n' "$*"; }
bad()  { printf '  \033[1;31mFAIL\033[0m %s\n' "$*"; FAIL=1; }
warn() { printf '  \033[1;33mWARN\033[0m %s\n' "$*"; }
check() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }

echo "== Guardrail objects"
check "GuardrailConfig default exists"           oc get guardrailconfig default
for p in guardrails-critical-delete guardrails-gitops-only-mutation guardrails-rbac-escalation-audit; do
  check "ValidatingAdmissionPolicy $p"            oc get validatingadmissionpolicy "$p"
  W="$(oc get validatingadmissionpolicy "$p" -o jsonpath='{.status.typeChecking.expressionWarnings[*].warning}' 2>/dev/null | wc -w)"
  [[ "$W" -gt 0 ]] && warn "$p has $W type-checking warning words (expected for multi-kind policies; confirm no 'compilation' errors: oc get vap $p -o yaml | grep -i error)"
  C="$(oc get validatingadmissionpolicy "$p" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)"
  [[ "$C" == "True" ]] || warn "$p Ready condition is '$C'"
done
for b in guardrails-critical-delete-labelled guardrails-critical-delete-named guardrails-gitops-only-mutation guardrails-rbac-escalation-audit; do
  check "Binding $b" oc get validatingadmissionpolicybinding "$b"
  echo "       actions: $(oc get validatingadmissionpolicybinding "$b" -o jsonpath='{.spec.validationActions}' 2>/dev/null)"
done
check "Reaper CronJob"                           oc get cronjob approval-reaper -n guardrails-system
check "Break-glass SA"                           oc get sa breakglass -n guardrails-system

echo "== Identity"
if oc get secret kubeadmin -n kube-system >/dev/null 2>&1; then bad "kubeadmin secret still present (remove after IdP is verified)"; else ok "kubeadmin removed"; fi
N="$(oc get clusterrolebinding -o json | python3 -c 'import sys,json; d=json.load(sys.stdin); print(sum(1 for b in d["items"] if b["roleRef"]["name"]=="cluster-admin" for s in b.get("subjects",[]) if s["kind"]=="User"))' 2>/dev/null || echo "?")"
[[ "$N" == "0" ]] && ok "no User subjects bound directly to cluster-admin" || warn "$N User subject(s) bound directly to cluster-admin"
for g in gitops-deletion-approvers gitops-deletion-requesters platform-admins; do check "Group $g" oc get group "$g"; done
A="$(oc get group gitops-deletion-approvers -o jsonpath='{.users}' 2>/dev/null | tr ',' '\n' | wc -l)"
[[ "$A" -ge 4 ]] && ok "approver group has $A members" || warn "approver group has only $A member(s); need >= 4 for the two-person rule to be workable"

echo "== Audit"
P="$(oc get apiserver cluster -o jsonpath='{.spec.audit.profile}' 2>/dev/null)"
[[ "$P" == "WriteRequestBodies" ]] && ok "audit profile WriteRequestBodies" || bad "audit profile is '$P'"
check "ClusterLogForwarder audit-forwarder"      oc get clusterlogforwarder audit-forwarder -n openshift-logging
R="$(oc get clusterlogforwarder audit-forwarder -n openshift-logging -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)"
[[ "$R" == "True" ]] && ok "forwarder Ready" || bad "forwarder Ready=$R (oc describe clf audit-forwarder -n openshift-logging)"
check "LokiStack logging-loki"                    oc get lokistack logging-loki -n openshift-logging
check "AlertingRule guardrails-audit-alerts"     oc get alertingrule guardrails-audit-alerts -n openshift-logging
check "PrometheusRule guardrails-gitops-health"  oc get prometheusrule guardrails-gitops-health -n openshift-gitops

echo "== Alertmanager"
if oc -n openshift-monitoring get secret alertmanager-main -o jsonpath='{.data.alertmanager\.yaml}' | base64 -d | grep -q msteamsv2_configs; then ok "Teams receiver configured"; else bad "msteamsv2_configs missing in alertmanager-main"; fi
if oc -n openshift-monitoring get secret alertmanager-main -o jsonpath='{.data.alertmanager\.yaml}' | base64 -d | grep -q 'guardrail="true"'; then ok "guardrail route configured"; else bad "guardrail route missing"; fi
check "Alertmanager pods running"                 oc get pods -n openshift-monitoring -l app.kubernetes.io/name=alertmanager --field-selector=status.phase=Running

echo "== Argo CD"
check "ArgoCD CR openshift-gitops"                oc get argocd openshift-gitops -n openshift-gitops
D="$(oc get argocd openshift-gitops -n openshift-gitops -o jsonpath='{.spec.disableAdmin}' 2>/dev/null)"; [[ "$D" == "true" ]] && ok "local admin disabled" || warn "spec.disableAdmin=$D"
check "Application guardrails"                    oc get application guardrails -n openshift-gitops
F="$(oc get application guardrails -n openshift-gitops -o jsonpath='{.metadata.finalizers}' 2>/dev/null)"; [[ -z "$F" ]] && ok "guardrails app has no cascade finalizer" || bad "guardrails app has finalizers: $F"
echo "  critical-labelled objects:"; oc get argocd,application,appproject -A -l guardrails.example.com/critical=true --no-headers 2>/dev/null | sed 's/^/    /'

echo "== Backup"
check "DPA gitops-dpa"                            oc get dpa gitops-dpa -n openshift-adp
check "Schedule gitops-6h"                        oc get schedule gitops-6h -n openshift-adp
L="$(oc get backup -n openshift-adp --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1:].status.phase}' 2>/dev/null)"; [[ "$L" == "Completed" ]] && ok "last backup Completed" || warn "last backup phase: '${L:-none}'"

echo; [[ $FAIL -eq 0 ]] && printf '\033[1;32mALL HARD CHECKS PASSED\033[0m\n' || printf '\033[1;31mSOME CHECKS FAILED\033[0m\n'
exit $FAIL
