#!/usr/bin/env bash
# PRIVATE HOST. Removes model servers and router. CRDs are cluster-wide: removed only with --crds.
source "$(dirname "$0")/lib.sh"
need kubectl helm
[[ -f $WORK/modelserver.yaml ]] && kubectl -n "$NAMESPACE" delete -f "$WORK/modelserver.yaml" --ignore-not-found
helm uninstall "$RELEASE" -n "$NAMESPACE" 2>/dev/null || true
if [[ ${1:-} == --crds ]]; then
  warn "deleting InferencePool CRD: removes ALL InferencePools cluster-wide"
  kubectl delete -f "$BUNDLE/gaie-${GAIE_VERSION}-v1-manifests.yaml" --ignore-not-found
fi
ok "done (namespace $NAMESPACE kept; delete with: kubectl delete ns $NAMESPACE)"
