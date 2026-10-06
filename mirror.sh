#!/usr/bin/env bash
# Run on a connected bastion. Copies everything optimized-baseline v0.9.0 needs into Artifact Registry.
# Needs: crane (or gcrane), helm, gcloud auth configure-docker ${AR_HOST}
set -euo pipefail
: "${AR:?set AR, e.g. us-central1-docker.pkg.dev/my-proj/llm-d}"

IMAGES=(
  docker.io/vllm/vllm-openai:v0.26.0                      # model server (guides/recipes/modelserver/components/images/gpu-vllm/release)
  ghcr.io/llm-d/llm-d-router-endpoint-picker:v0.10.0      # EPP (router chart v0.10.0)
  docker.io/envoyproxy/envoy:distroless-v1.33.2           # standalone proxy sidecar
  docker.io/cfmanteiga/alpine-bash-curl-jq:latest         # verification pod only
)
for img in "${IMAGES[@]}"; do
  crane copy "$img" "${AR}/${img#*/}"   # keeps repo path, drops registry host
done

# Router helm chart -> AR as OCI
helm pull oci://ghcr.io/llm-d/charts/llm-d-router-standalone --version v0.10.0
helm push llm-d-router-standalone-v0.10.0.tgz "oci://${AR}/charts"

# GAIE CRDs (GAIE_VERSION=v1.5.0 from guides/env.sh)
curl -fsSLo gaie-v1-manifests.yaml \
  https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases/download/v1.5.0/v1-manifests.yaml
