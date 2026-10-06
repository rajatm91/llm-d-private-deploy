#!/usr/bin/env bash
# PRIVATE HOST. Renders the gke-airgap overlay on top of the upstream optimized-baseline GKE overlay and applies it.
# Pods carry label llm-d.ai/guide=optimized-baseline, which the router's InferencePool selects.
source "$(dirname "$0")/lib.sh"
need kubectl
ensure_src
read -r v_reg v_repo v_tag <<<"$(split_image "$VLLM_IMAGE")"
dst=$GUIDE/modelserver/gpu/vllm/gke-airgap
mkdir -p "$dst"
for f in kustomization.yaml patch-airgap.yaml; do
  sed -e "s|__VLLM_IMAGE_NAME__|$v_reg/$v_repo|" -e "s|__VLLM_IMAGE_TAG__|$v_tag|" \
      -e "s|__REPLICAS__|$REPLICAS|" -e "s|__TP__|$TP|g" -e "s|__MODEL_ID__|$MODEL_ID|g" \
      -e "s|__MODEL_BUCKET__|$MODEL_BUCKET|" -e "s|__GCSFUSE_FILE_CACHE__|$GCSFUSE_FILE_CACHE|" \
      "$ROOT/templates/gke-airgap/$f" > "$dst/$f"
done

log "1/3 Render and check"
kubectl kustomize "$dst" > "$WORK/modelserver.yaml"
assert_no_public_images "$WORK/modelserver.yaml"

log "2/3 Apply"
kubectl apply -n "$NAMESPACE" -f "$WORK/modelserver.yaml"

log "3/3 Wait for $REPLICAS replicas (model load from GCS can take 10-30 min)"
end=$((SECONDS + ${WAIT_MIN:-60}*60))
while (( SECONDS < end )); do
  ready=$(kubectl -n "$NAMESPACE" get deploy "$MS_DEPLOY" -o jsonpath='{.status.readyReplicas}')
  echo "      ready ${ready:-0}/$REPLICAS  $(kubectl -n "$NAMESPACE" get pods -l llm-d.ai/guide=optimized-baseline,llm-d.ai/model --no-headers 2>/dev/null | awk '{print $3}' | sort | uniq -c | tr '\n' ' ')"
  [[ ${ready:-0} == "$REPLICAS" ]] && { ok "all replicas ready"; exit 0; }
  sleep 30
done
die "timed out; check: kubectl -n $NAMESPACE logs deploy/$MS_DEPLOY -c modelserver"
