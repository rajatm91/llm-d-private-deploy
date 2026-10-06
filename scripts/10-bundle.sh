#!/usr/bin/env bash
# CONNECTED HOST. Mirrors images into Artifact Registry and builds the offline bundle
# (GAIE CRDs, router chart, llm-d source, these scripts) for the private side.
# Needs: gcloud, crane, helm, curl, tar.
source "$(dirname "$0")/lib.sh"
need gcloud crane helm curl tar

log "1/5 Artifact Registry auth for crane/helm ($AR_HOST)"
gcloud auth configure-docker "$AR_HOST" --quiet >/dev/null
ok "docker credential helper configured"

log "2/5 Images (MIRROR_MODE=$MIRROR_MODE)"
pairs=(
  "$VLLM_UPSTREAM|$VLLM_IMAGE"
  "$EPP_UPSTREAM|$EPP_IMAGE"
  "$ENVOY_UPSTREAM|$ENVOY_IMAGE"
  "$CURL_UPSTREAM|$CURL_IMAGE"
)
for p in "${pairs[@]}"; do
  src=${p%%|*} dst=${p##*|}
  case $MIRROR_MODE in
    copy)   crane copy "$src" "$dst" ;;                 # all platforms, keeps digest
    remote) : ;;                                        # AR remote repo fetches on first read
    *)      die "MIRROR_MODE must be copy|remote" ;;
  esac
  ok "$dst  $(crane digest "$dst")"
done

log "3/5 GAIE ${GAIE_VERSION} CRDs"
mkdir -p "$BUNDLE"
curl -fsSL -o "$BUNDLE/gaie-${GAIE_VERSION}-v1-manifests.yaml" \
  "https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases/download/${GAIE_VERSION}/v1-manifests.yaml"
ok "gaie-${GAIE_VERSION}-v1-manifests.yaml"

log "4/5 Router chart ${ROUTER_CHART}:${ROUTER_CHART_VERSION} + llm-d ${LLMD_REF} source"
helm pull "oci://ghcr.io/llm-d/charts/${ROUTER_CHART}" --version "$ROUTER_CHART_VERSION" -d "$BUNDLE"
if [[ -n $CHART_OCI_REPO ]]; then
  gcloud auth print-access-token | helm registry login -u oauth2accesstoken --password-stdin "https://$AR_HOST"
  helm push "$BUNDLE/${ROUTER_CHART}-${ROUTER_CHART_VERSION}.tgz" "$CHART_OCI_REPO"
  ok "pushed chart to $CHART_OCI_REPO/${ROUTER_CHART}"
fi
curl -fsSL -o "$BUNDLE/llm-d-${LLMD_REF}.tar.gz" "https://github.com/llm-d/llm-d/archive/refs/tags/${LLMD_REF}.tar.gz"
(cd "$BUNDLE" && sha *.yaml *.tgz *.tar.gz > SHA256SUMS)
ok "bundle/ + SHA256SUMS"

log "5/5 Packing"
out=$ROOT/../llm-d-airgap-bundle.tgz
tar -czf "$out" -C "$ROOT/.." --exclude='*/work' --exclude='*/.git' "$(basename "$ROOT")"
ok "$out ($(du -h "$out" | cut -f1))"
if [[ -n $BUNDLE_GCS ]]; then
  gcloud storage cp "$out" "$BUNDLE_GCS/"
  ok "uploaded to $BUNDLE_GCS/$(basename "$out")"
fi
