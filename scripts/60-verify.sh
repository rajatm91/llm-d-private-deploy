#!/usr/bin/env bash
# PRIVATE HOST. End-to-end check through the router: client -> Service ${RELEASE}-epp:80 -> Envoy -> EPP picks pod -> vLLM.
source "$(dirname "$0")/lib.sh"
need kubectl
ip=$(kubectl -n "$NAMESPACE" get svc "${RELEASE}-epp" -o jsonpath='{.spec.clusterIP}')
log "Router endpoint http://$ip (Service ${RELEASE}-epp)"
kubectl -n "$NAMESPACE" get pods -l llm-d.ai/guide=optimized-baseline -o wide | sed 's/^/      /'

log "Requests from an in-cluster curl pod"
kubectl -n "$NAMESPACE" run curl-verify --rm -i --restart=Never --image="$CURL_IMAGE" \
  --env="IP=$ip" --env="MODEL=$MODEL_ID" -- /bin/sh -c '
set -e
echo "--- GET /v1/models"; curl -sS --fail-with-body "http://$IP/v1/models" | jq -c ".data[].id"
echo "--- POST /v1/completions"
curl -sS --fail-with-body "http://$IP/v1/completions" -H "Content-Type: application/json" \
  -d "{\"model\":\"$MODEL\",\"prompt\":\"How are you today?\",\"max_tokens\":32}" | jq -c "{model, text: .choices[0].text, usage}"
echo "--- 10 requests sharing a prefix (prefix-cache affinity should pin them)"
for i in $(seq 1 10); do
  curl -sS -o /dev/null -w "%{http_code} %{time_total}s\n" "http://$IP/v1/completions" -H "Content-Type: application/json" \
    -d "{\"model\":\"$MODEL\",\"prompt\":\"You are a helpful assistant. Shared system prompt for routing test. Question $i\",\"max_tokens\":8}"
done'
log "EPP routing decisions (last lines)"
kubectl -n "$NAMESPACE" logs "deploy/${RELEASE}-epp" -c epp --tail=15 | sed 's/^/      /'
