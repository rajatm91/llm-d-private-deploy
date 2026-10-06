#!/usr/bin/env bash
# PRIVATE HOST. Installs the Gateway API Inference Extension (GAIE) CRDs from the bundle.
# GAIE v1.5.0 "v1-manifests.yaml" = one cluster-scoped CRD: inferencepools.inference.networking.k8s.io (v1).
# The router chart creates an InferencePool object of this kind; EPP watches it to find model-server pods.
source "$(dirname "$0")/lib.sh"
need kubectl
CRD=inferencepools.inference.networking.k8s.io
f=$BUNDLE/gaie-${GAIE_VERSION}-v1-manifests.yaml
[[ -f $f ]] || die "missing $f"

log "1/4 What the bundle contains"
grep -E '^kind:|^  name:' "$f" | paste - - | sed 's/^/      /'

log "2/4 Existing CRD"
if kubectl get crd "$CRD" >/dev/null 2>&1; then
  ok "present; versions=$(kubectl get crd $CRD -o jsonpath='{.spec.versions[*].name}') bundle-version=$(kubectl get crd $CRD -o jsonpath='{.metadata.annotations.inference\.networking\.k8s\.io/bundle-version}')"
  mode=$(kubectl get crd "$CRD" -o jsonpath='{.metadata.labels.addonmanager\.kubernetes\.io/mode}')
  if [[ -n $mode ]]; then
    warn "CRD is managed by GKE (addonmanager mode=$mode, e.g. GKE Inference Gateway). Not overwriting."
    SKIP_APPLY=1
  fi
else
  ok "not installed"
fi

if [[ -z ${SKIP_APPLY:-} ]]; then
  log "3/4 Apply (server-side, idempotent)"
  kubectl apply --server-side --force-conflicts -f "$f"
fi

log "4/4 Verify"
kubectl wait --for=condition=Established "crd/$CRD" --timeout=120s
[[ $(kubectl get crd "$CRD" -o jsonpath='{.spec.versions[?(@.name=="v1")].served}') == true ]] \
  || die "$CRD does not serve v1; router ${ROUTER_CHART_VERSION} needs inference.networking.k8s.io/v1"
kubectl api-resources --api-group=inference.networking.k8s.io
ok "GAIE CRDs ready"
