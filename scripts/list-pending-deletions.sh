#!/usr/bin/env bash
# List every open deletion request on the cluster: object, requester, request time, approvals so far, remaining.
# Read-only. Scans the same Tier-A kinds as the approval reaper (kinds you may not list are skipped silently).
#   ./list-pending-deletions.sh
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
NEED="$(min_approvers)"
KINDS="configmaps guardrailconfigs.v1alpha1.guardrails.example.com argocds.v1beta1.argoproj.io applications.v1alpha1.argoproj.io
applicationsets.v1alpha1.argoproj.io appprojects.v1alpha1.argoproj.io roles.v1.rbac.authorization.k8s.io rolebindings.v1.rbac.authorization.k8s.io
lokistacks.v1.loki.grafana.com alertingrules.v1.loki.grafana.com rulerconfigs.v1.loki.grafana.com clusterlogforwarders.v1.observability.openshift.io
prometheusrules.v1.monitoring.coreos.com alertmanagerconfigs.v1alpha1.monitoring.coreos.com schedules.v1.velero.io backupstoragelocations.v1.velero.io
dataprotectionapplications.v1alpha1.oadp.openshift.io cronjobs.v1.batch networkpolicies.v1.networking.k8s.io"
TPL='{{range .items}}{{$i := .}}{{with .metadata.annotations}}{{if index . "guardrails.example.com/delete-request"}}{{with $i.metadata.namespace}}{{.}}{{end}}|{{$i.metadata.name}}|{{index . "guardrails.example.com/delete-requested-by"}}|{{with index . "guardrails.example.com/delete-requested-at"}}{{.}}{{end}}|{{with index . "guardrails.example.com/delete-approvals"}}{{.}}{{end}}{{"\n"}}{{end}}{{end}}{{end}}'
printf '%-28s %-44s %-28s %-21s %-5s %s\n' KIND NAMESPACE/NAME REQUESTED-BY REQUESTED-AT HAVE REMAINING
FOUND=0
for K in $KINDS; do
  while IFS='|' read -r NS NAME BY AT RAW; do
    [[ -z "$NAME" ]] && continue
    FOUND=$((FOUND + 1)); HAVE=0; SEEN=" "
    if [[ -n "$RAW" ]]; then
      IFS=',' read -r -a ENTRIES <<< "$RAW"
      for E in "${ENTRIES[@]}"; do U="${E%%|*}"; if [[ "$SEEN" != *" $U "* && "$U" != "$BY" ]]; then SEEN="$SEEN$U "; HAVE=$((HAVE + 1)); fi; done
    fi
    REM=$(( NEED > HAVE ? NEED - HAVE : 0 ))
    printf '%-28s %-44s %-28s %-21s %-5s %s\n' "${K%%.*}" "${NS:-<cluster>}/$NAME" "$BY" "${AT:-<none>}" "$HAVE/$NEED" "$([[ $REM -eq 0 ]] && echo 'ready to execute' || echo "$REM")"
  done < <(oc get "$K" --all-namespaces --ignore-not-found -o go-template="$TPL" 2>/dev/null || true)
done
[[ $FOUND -eq 0 ]] && echo "(no open deletion requests)"
echo "Details: scripts/status-deletion.sh <kind> <name> [-n <ns>]   (approvals older than $(approval_ttl) are removed by the reaper)"
