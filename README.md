# llm-d-private-deploy

Air-gapped GKE deployment of the llm-d [optimized-baseline](https://github.com/llm-d/llm-d/tree/release-0.9/guides/optimized-baseline) well-lit path, llm-d **v0.9.0** (`release-0.9`).

## What gets mirrored

| Item | Source |
|---|---|
| vLLM image | `docker.io/vllm/vllm-openai:v0.26.0` |
| EPP image | `ghcr.io/llm-d/llm-d-router-endpoint-picker:v0.10.0` |
| Envoy sidecar | `docker.io/envoyproxy/envoy:distroless-v1.33.2` |
| Test curl image | `docker.io/cfmanteiga/alpine-bash-curl-jq:latest` |
| Router chart | `oci://ghcr.io/llm-d/charts/llm-d-router-standalone:v0.10.0` |
| GAIE CRDs | `gateway-api-inference-extension` `v1.5.0/v1-manifests.yaml` |
| Model weights | `Qwen/Qwen3-32B` (~65 GB) |

## Files

- `mirror.sh` — run on a connected bastion; copies images + chart to Artifact Registry, downloads GAIE CRDs.
- `router-airgap.values.yaml` — EPP + Envoy image overrides; layer last.
- `gke-airgap/` — Kustomize overlay on the guide's `gke` overlay: mirrored vLLM image, model from GCS FUSE at `/models`, `--served-model-name=Qwen/Qwen3-32B`, no `HF_TOKEN`, offline + telemetry-off env.

Replace `MY_PROJECT` and `MY_MODEL_BUCKET` everywhere.

## Steps

### 0. Cluster prerequisites
- Private GKE cluster, no NAT. Private Google Access on the subnet; DNS for `*.googleapis.com`, `*.pkg.dev`, `*.gcr.io` to the private/restricted VIP (GPU driver installer and gcsfuse sidecar come from Google registries).
- Workload Identity and the GCS FUSE CSI driver add-on enabled.
- GPU node pool (A3 H100) with `gpu-driver-version=latest`.
- Node service account has `roles/artifactregistry.reader`.
- Defaults need 16 H100 (8 replicas x TP=2). Fewer GPUs: lower `replicas` in the patch.

### 1. Bastion (connected): mirror and stage model
```bash
export AR=us-central1-docker.pkg.dev/MY_PROJECT/llm-d
gcloud auth print-access-token | helm registry login -u oauth2accesstoken --password-stdin https://us-central1-docker.pkg.dev
./mirror.sh
hf download Qwen/Qwen3-32B --local-dir ./Qwen/Qwen3-32B
gcloud storage cp -r ./Qwen gs://MY_MODEL_BUCKET/
```
No connected bastion at all: `crane pull` to tarballs, carry across, `crane push`.

### 2. Clone llm-d, add overlay, set env
```bash
git clone https://github.com/llm-d/llm-d.git && cd llm-d && git checkout release-0.9
cp -R ../llm-d-private-deploy/gke-airgap guides/optimized-baseline/modelserver/gpu/vllm/
export REPO_ROOT=$PWD GUIDE_NAME=optimized-baseline NAMESPACE=llm-d-optimized-baseline \
  ROUTER_CHART_VERSION=v0.10.0 MODEL=Qwen/Qwen3-32B
```
Pin `ROUTER_CHART_VERSION=v0.10.0`. The guide sets `v0`, which makes Helm resolve the latest version from the registry.

### 3. CRDs and namespace
```bash
kubectl apply -f gaie-v1-manifests.yaml
kubectl create namespace ${NAMESPACE}
```
No HF token secret needed.

### 4. Bucket access for the model server KSA
```bash
gcloud storage buckets add-iam-policy-binding gs://MY_MODEL_BUCKET \
  --role=roles/storage.objectViewer \
  --member=principal://iam.googleapis.com/projects/PROJECT_NUMBER/locations/global/workloadIdentityPools/MY_PROJECT.svc.id.goog/subject/ns/llm-d-optimized-baseline/sa/optimized-baseline-nvidia-gpu-vllm-sa
```

### 5. Router (standalone mode)
```bash
helm install ${GUIDE_NAME} oci://${AR}/charts/llm-d-router-standalone \
  --version ${ROUTER_CHART_VERSION} -n ${NAMESPACE} \
  -f guides/recipes/router/base.values.yaml \
  -f guides/optimized-baseline/router/optimized-baseline.values.yaml \
  -f ../llm-d-private-deploy/router-airgap.values.yaml
```

### 6. Model server
```bash
kubectl apply -n ${NAMESPACE} -k guides/optimized-baseline/modelserver/gpu/vllm/gke-airgap/
```

### 7. Verify
```bash
export IP=$(kubectl get svc ${GUIDE_NAME}-epp -n ${NAMESPACE} -o jsonpath='{.spec.clusterIP}')
kubectl run curl-test --rm -i --restart=Never -n ${NAMESPACE} \
  --image=${AR}/cfmanteiga/alpine-bash-curl-jq:latest --env="IP=${IP}" \
  -- /bin/sh -c 'curl -sS http://${IP}/v1/completions -H "Content-Type: application/json" -d "{\"model\":\"Qwen/Qwen3-32B\",\"prompt\":\"hi\"}"'
```

## Gotchas
- Benchmarking (`llmdbenchmark`) and the monitoring stack are not covered; both need their own offline packaging.
- Smoke-test one pod with egress blocked; vLLM may attempt network calls for kernel JIT/compile caches.
- Instead of GCS FUSE, a Hyperdisk ML or Filestore PVC at `/models` works; swap only the volume.
- Other GPUs/models: recalibrate `peakPrefillThroughput` with `guides/recipes/router/calibration` (default tuned for Qwen3-32B on H100, TP=2).
