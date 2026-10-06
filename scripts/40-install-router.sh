#!/usr/bin/env bash
# PRIVATE HOST. Installs the llm-d router (standalone mode): EPP + Envoy sidecar in one pod,
# Service ${RELEASE}-epp (:80 -> envoy :8081, :9002 ext-proc, :9090 metrics), RBAC, InferencePool.
# Values layering = upstream guide (base + optimized-baseline) + image overrides from config.env.
source "$(dirname "$0")/lib.sh"
need helm kubectl
ensure_src
kubectl get crd inferencepools.inference.networking.k8s.io >/dev/null 2>&1 || die "GAIE CRD missing; run 30-install-gaie-crds.sh"

if [[ -n $CHART_OCI_REPO ]]; then
  gcloud auth print-access-token | helm registry login -u oauth2accesstoken --password-stdin "https://$AR_HOST" >/dev/null
  chart=("$CHART_OCI_REPO/$ROUTER_CHART" --version "$ROUTER_CHART_VERSION")
else
  chart=("$BUNDLE/${ROUTER_CHART}-${ROUTER_CHART_VERSION}.tgz")
  [[ -f ${chart[0]} ]] || die "missing ${chart[0]}"
fi

read -r epp_reg epp_repo epp_tag <<<"$(split_image "$EPP_IMAGE")"
args=(
  "$RELEASE" "${chart[@]}" -n "$NAMESPACE"
  -f "$SRC/guides/recipes/router/base.values.yaml"
  -f "$GUIDE/router/optimized-baseline.values.yaml"
  --set "router.epp.image.registry=$epp_reg"
  --set "router.epp.image.repository=$epp_repo"
  --set "router.epp.image.tag=$epp_tag"
  --set "router.proxy.image=$ENVOY_IMAGE"
  ${MONITORING:+-f "$SRC/guides/recipes/router/features/monitoring.values.yaml"}
)

log "1/4 Render and check images"
mkdir -p "$WORK"
helm template "${args[@]}" > "$WORK/router.yaml"
assert_no_public_images "$WORK/router.yaml"
grep -E '^kind:' "$WORK/router.yaml" | sort | uniq -c | sed 's/^/      /'

log "2/4 Install/upgrade release $RELEASE in $NAMESPACE"
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
helm upgrade --install "${args[@]}"

log "3/4 Wait for EPP pod (containers: envoy-proxy, epp)"
if ! kubectl -n "$NAMESPACE" rollout status "deploy/${RELEASE}-epp" --timeout=300s; then
  kubectl -n "$NAMESPACE" describe pod -l "llm-d-router-gateway=${RELEASE}-epp" | tail -30
  kubectl -n "$NAMESPACE" logs "deploy/${RELEASE}-epp" -c epp --tail=50 || true
  die "EPP not ready"
fi

log "4/4 Verify objects"
kubectl -n "$NAMESPACE" get deploy,svc,inferencepool -l "app.kubernetes.io/name=${RELEASE}-epp" 2>/dev/null \
  || kubectl -n "$NAMESPACE" get deploy,svc,inferencepool
kubectl -n "$NAMESPACE" get inferencepool "$RELEASE" -o jsonpath='{.spec.selector.matchLabels}{"\n"}' | sed 's/^/      pool selects pods with: /'
ok "router installed. Model-server pods appear in the pool after 50-deploy-modelserver.sh"
