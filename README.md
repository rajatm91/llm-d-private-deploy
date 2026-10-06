# llm-d-private-deploy

Air-gapped GKE deployment of the llm-d **optimized-baseline** well-lit path, llm-d **v0.9.0**
(upstream guide: [`guides/optimized-baseline` @ release-0.9](https://github.com/llm-d/llm-d/tree/release-0.9/guides/optimized-baseline)).

Everything is driven by one file, [`config.env`](config.env), and numbered scripts in [`scripts/`](scripts/).

---

## 1. What gets installed

```
 client ──HTTP──▶ Service <release>-epp :80
                     │
                     ▼
        ┌──────── EPP pod (Helm: llm-d-router-standalone) ────────┐
        │  envoy-proxy :8081 ──ext-proc gRPC :9002──▶ epp          │
        │       │            ◀── "send to pod X" ────  │          │
        └───────┼──────────────────────────────────────┼──────────┘
                │                                       │ watches
                │                                       ▼
                │                       InferencePool <release>   (CRD from GAIE)
                │                       selector: llm-d.ai/guide=optimized-baseline
                ▼                                       │
        vLLM pods :8000  ◀───────────────────────────────┘
        (Kustomize: optimized-baseline-nvidia-gpu-vllm-decode, model from GCS FUSE)
```

| Layer | What | Installed by |
|---|---|---|
| **Gateway API Inference Extension (GAIE) CRDs** | One cluster-scoped CRD: `inferencepools.inference.networking.k8s.io` (version `v1`). Describes "a pool of model-server pods + which endpoint picker routes to them". | `scripts/30-install-gaie-crds.sh` |
| **llm-d router** (standalone mode) | Helm chart `llm-d-router-standalone`. One pod with two containers: **Envoy** (data plane, receives client traffic) and **EPP / endpoint picker** (decides which vLLM pod gets each request using prefix-cache affinity + token-load scoring). Plus Service, RBAC, ConfigMaps, and an `InferencePool` object. | `scripts/40-install-router.sh` |
| **Model servers** | 8 × vLLM (TP=2) Deployment, weights read from a GCS bucket via GCS FUSE, fully offline. | `scripts/50-deploy-modelserver.sh` |

"Standalone mode" means no Kubernetes Gateway / GKE Gateway controller is needed: Envoy runs as a sidecar
next to the EPP. This is the upstream default and the simplest option on a private cluster.

### Pinned versions (llm-d v0.9.0)

| Component | Version | Upstream |
|---|---|---|
| GAIE CRDs | v1.5.0 | `github.com/kubernetes-sigs/gateway-api-inference-extension/releases/download/v1.5.0/v1-manifests.yaml` |
| Router Helm chart | v0.10.0 | `oci://ghcr.io/llm-d/charts/llm-d-router-standalone` |
| EPP image | v0.10.0 | `ghcr.io/llm-d/llm-d-router-endpoint-picker` |
| Envoy image | distroless-v1.33.2 | `docker.io/envoyproxy/envoy` |
| vLLM image | v0.26.0 | `docker.io/vllm/vllm-openai` |
| Test image | latest | `docker.io/cfmanteiga/alpine-bash-curl-jq` |
| Model | Qwen/Qwen3-32B | Hugging Face (~65 GB) |

> The v1.5.0 CRD file carries the annotation `bundle-version: v1.5.0-rc.2`. That is upstream's labelling; the file is the official v1.5.0 release asset.

---

## 2. Where each step runs

| Host | Network | Steps |
|---|---|---|
| **Connected host** (laptop / bastion with internet + gcloud) | Internet + GCP APIs | `10-bundle.sh`, `15-stage-model.sh` |
| **Private host** (inside the VPC, `kubectl` to the cluster, no internet) | GCP APIs via Private Google Access | `20` → `60` |

The bundle travels between them through a GCS bucket (`BUNDLE_GCS`), so it never needs internet on the private side.

Tools: connected host needs `gcloud`, `helm` ≥ 3.8, `crane`, `curl`, `tar`, `hf` (only for step 15).
Private host needs `gcloud`, `kubectl`, `helm` ≥ 3.8, `tar`. `crane`:
`go install github.com/google/go-containerregistry/cmd/crane@latest` or a binary from its GitHub releases.

---

## 3. GKE prerequisites (check once)

```bash
export PROJECT_ID=my-project CLUSTER_NAME=my-gke-cluster CLUSTER_LOCATION=us-central1
```

**Private cluster, Workload Identity, GCS FUSE add-on:**
```bash
gcloud container clusters describe $CLUSTER_NAME --location $CLUSTER_LOCATION --format="yaml(privateClusterConfig.enablePrivateNodes,workloadIdentityConfig,addonsConfig.gcsFuseCsiDriverConfig)"
```
Enable what's missing:
```bash
gcloud container clusters update $CLUSTER_NAME --location $CLUSTER_LOCATION --workload-pool=$PROJECT_ID.svc.id.goog
```
```bash
gcloud container clusters update $CLUSTER_NAME --location $CLUSTER_LOCATION --update-addons GcsFuseCsiDriver=ENABLED
```

**Private Google Access** on the node subnet. Nodes pull from Artifact Registry, and GKE pulls its own GPU-driver and gcsfuse sidecar images, over this path:
```bash
gcloud compute networks subnets describe SUBNET --region REGION --format="value(privateIpGoogleAccess)"
```
If you use restricted.googleapis.com / private.googleapis.com, Cloud DNS must also resolve `*.pkg.dev`, `*.gcr.io` and `*.googleapis.com` to that VIP.

**GPU node pool:** A3 (H100 80 GB) with GKE-managed drivers (`--accelerator type=nvidia-h100-80gb,count=8,gpu-driver-version=latest`). The defaults need 16 GPUs; lower `REPLICAS` / `TP` in `config.env` if you have fewer.

**Node service account can read your AR repo:**
```bash
gcloud artifacts repositories add-iam-policy-binding REPO --location REGION --member=serviceAccount:NODE_SA_EMAIL --role=roles/artifactregistry.reader
```

---

## 4. Configure

```bash
cp config.env config.env.orig && $EDITOR config.env
```

Set at minimum: `PROJECT_ID`, `REGION`, `CLUSTER_NAME`, `CLUSTER_LOCATION`, `AR`, `MODEL_BUCKET`, `BUNDLE_GCS`.

### Your existing Artifact Registry mirror repo

Check what kind of repo it is:
```bash
gcloud artifacts repositories describe REPO --location REGION --format="value(mode,format)"
```

| Mode | Set | Image refs |
|---|---|---|
| `STANDARD_REPOSITORY` | `MIRROR_MODE=copy` | Keep the defaults: `10-bundle.sh` pushes each image to `${AR}/<upstream path>`, e.g. `${AR}/vllm/vllm-openai:v0.26.0`. |
| `REMOTE_REPOSITORY` (pull-through) | `MIRROR_MODE=remote` | Nothing is pushed; AR fetches from upstream on first pull. A Docker Hub remote serves `vllm/vllm-openai`, `envoyproxy/envoy` and `cfmanteiga/alpine-bash-curl-jq`. `ghcr.io` needs its **own** remote repo (custom upstream `https://ghcr.io`). Set `EPP_IMAGE` to point at it, e.g. `us-central1-docker.pkg.dev/PROJ/ghcr-remote/llm-d/llm-d-router-endpoint-picker:v0.10.0`. |

Remote repos are read-only, so the Helm chart can't be pushed there. Leave `CHART_OCI_REPO` empty and the chart installs from the bundled `.tgz`, which is the default.

All four `*_IMAGE` variables are the exact refs the cluster pulls. Every script reads them; nothing else is hard-coded.

---

## 5. Connected host

### Step A1: mirror images and build the bundle
```bash
./scripts/10-bundle.sh
```
What it does:
1. `gcloud auth configure-docker $AR_HOST` so `crane`/`helm` can push.
2. **Images.** `copy` mode runs `crane copy` for all 4 images (all platforms, digests preserved). `remote` mode only resolves each ref, which also warms the AR cache. Each image's digest is printed.
3. Downloads the **GAIE v1.5.0 CRD** file into `bundle/`.
4. `helm pull` of the **router chart v0.10.0** into `bundle/`, plus an optional push to `CHART_OCI_REPO`. Downloads the **llm-d v0.9.0 source** tarball, which has the guide's Helm values and Kustomize bases.
5. Writes `bundle/SHA256SUMS`, packs this repo with `bundle/` into `../llm-d-airgap-bundle.tgz`, and uploads it to `BUNDLE_GCS`.

Docker Hub rate limits: run `docker login` before this step if `crane copy` returns 429.

### Step A2: stage the model in GCS
```bash
./scripts/15-stage-model.sh
```
This runs `hf download Qwen/Qwen3-32B`, then `gcloud storage rsync` to `gs://$MODEL_BUCKET/Qwen/Qwen3-32B/`. The path under the bucket must equal `MODEL_ID`.

---

## 6. Private host

### Step B0: fetch the bundle
```bash
gcloud storage cp gs://my-transfer-bucket/llm-d/llm-d-airgap-bundle.tgz . && tar -xzf llm-d-airgap-bundle.tgz && cd llm-d-private-deploy
```
(The directory name is whatever your clone was called on the connected host.)

### Step B1: preflight
```bash
./scripts/20-preflight.sh
```
Read-only checks, except for short-lived pull-test pods:

| # | Check | Fails when |
|---|---|---|
| 1 | Bundle checksums; extracts llm-d source to `work/llm-d` | corrupted copy |
| 2 | API server reachable, permission to create CRDs | wrong context / not cluster-admin |
| 3 | Allocatable `nvidia.com/gpu` ≥ `REPLICAS × TP` | not enough GPUs |
| 4 | GCS FUSE CSI driver, Workload Identity | add-on disabled |
| 5 | Existing CRD / Helm release (warnings only) | — |
| 6 | Each image exists in AR (`gcloud artifacts docker images describe`) | not mirrored / wrong ref |
| 7 | **Real in-cluster pull** of EPP, Envoy and curl images | node SA lacks `artifactregistry.reader`, or Private Google Access / DNS broken |

`PULL_TEST_VLLM=1 ./scripts/20-preflight.sh` also pre-pulls the ~10 GB vLLM image onto a GPU node.

Fix every `!` line before continuing.

### Step B2: install the GAIE CRD (Inference Extension)
```bash
./scripts/30-install-gaie-crds.sh
```
What it does:
1. Lists the bundle contents. Expect exactly one `CustomResourceDefinition` named `inferencepools.inference.networking.k8s.io`.
2. If the CRD already exists, prints its versions. If it carries the `addonmanager.kubernetes.io/mode` label, GKE owns it (for example, GKE Inference Gateway is enabled) and the script **does not overwrite it**.
3. `kubectl apply --server-side --force-conflicts`, which is idempotent and safe to re-run.
4. Waits for `Established` and asserts `v1` is served. Router v0.10.0 creates `inference.networking.k8s.io/v1` InferencePools.

Manual equivalent:
```bash
kubectl apply --server-side -f bundle/gaie-v1.5.0-v1-manifests.yaml
```
```bash
kubectl wait --for=condition=Established crd/inferencepools.inference.networking.k8s.io --timeout=120s
```
```bash
kubectl api-resources --api-group=inference.networking.k8s.io
```
Expected: `inferencepools   infpool   inference.networking.k8s.io/v1   true   InferencePool`.

The CRD is cluster-wide: install it once per cluster and it's shared by every llm-d namespace. This step needs cluster-admin; every later step only needs namespace admin.

### Step B3: install the llm-d router
```bash
./scripts/40-install-router.sh
```
What it does:
1. **Values layering**, the same as upstream plus image overrides:
   - `work/llm-d/guides/recipes/router/base.values.yaml`: EPP and Envoy resources, Envoy args, `failureMode: FailOpen`
   - `work/llm-d/guides/optimized-baseline/router/optimized-baseline.values.yaml`: the scheduler config (`prefix-cache-affinity-filter` + `token-load-scorer`), Service port 80 → 8081, and the pool selector `llm-d.ai/guide=optimized-baseline`
   - `--set router.epp.image.{registry,repository,tag}` and `--set router.proxy.image` from `EPP_IMAGE` / `ENVOY_IMAGE`
2. Runs `helm template` into `work/router.yaml` and **aborts if any image still points at a public registry**. The expected objects are 1 Deployment, 1 Service, 1 ServiceAccount, 2 ConfigMaps, 2 Roles, 2 RoleBindings and 1 InferencePool.
3. `helm upgrade --install`, which is idempotent: re-running with changed config upgrades the release.
4. Waits for `deploy/<release>-epp` to be ready (containers `envoy-proxy` and `epp`). On failure it prints `describe` and EPP logs.
5. Shows the Deployment, Service and InferencePool, and the pool's label selector.

Manual equivalent:
```bash
helm upgrade --install optimized-baseline bundle/llm-d-router-standalone-v0.10.0.tgz -n llm-d-optimized-baseline --create-namespace -f work/llm-d/guides/recipes/router/base.values.yaml -f work/llm-d/guides/optimized-baseline/router/optimized-baseline.values.yaml --set router.epp.image.registry=REGION-docker.pkg.dev/PROJ/REPO/llm-d --set router.epp.image.repository=llm-d-router-endpoint-picker --set router.epp.image.tag=v0.10.0 --set router.proxy.image=REGION-docker.pkg.dev/PROJ/REPO/envoyproxy/envoy:distroless-v1.33.2
```

Inspect:
```bash
kubectl -n llm-d-optimized-baseline get deploy,svc,inferencepool
```
```bash
kubectl -n llm-d-optimized-baseline get configmap optimized-baseline-epp -o yaml
```
```bash
kubectl -n llm-d-optimized-baseline logs deploy/optimized-baseline-epp -c epp --tail=50
```

Installing the router **before** the model servers is expected. The pool is empty until step B5, and requests sent before then fail.

Prometheus `ServiceMonitor`: only if the Prometheus Operator CRDs exist, run `MONITORING=1 ./scripts/40-install-router.sh`.

### Step B4: give the model servers access to the bucket
```bash
./scripts/45-grant-bucket-access.sh
```
This binds `roles/storage.objectViewer` on `gs://$MODEL_BUCKET` to the Kubernetes SA `optimized-baseline-nvidia-gpu-vllm-sa`, using direct Workload Identity (no Google SA or annotation needed). It also checks that `config.json` is present in the bucket.

### Step B5: deploy the model servers
```bash
./scripts/50-deploy-modelserver.sh
```
What it does:
1. Renders `templates/gke-airgap/` from `config.env` into the upstream tree at `work/llm-d/guides/optimized-baseline/modelserver/gpu/vllm/gke-airgap/`. This overlay sits on the upstream `gke` overlay, which already includes the GKE NCCL tuner fix, and:
   - rewrites the vLLM image to `VLLM_IMAGE`
   - sets replicas and `--tensor-parallel-size` / GPU requests from `REPLICAS` / `TP`
   - serves `/models/$MODEL_ID` from GCS FUSE with `--served-model-name=$MODEL_ID`, so clients still use the Hugging Face name
   - removes `HF_TOKEN` and sets `HF_HUB_OFFLINE=1`, `TRANSFORMERS_OFFLINE=1`, `VLLM_NO_USAGE_STATS=1` and `DO_NOT_TRACK=1`
   - lifts the gcsfuse sidecar's limits and enables a parallel-download file cache
2. Runs `kubectl kustomize` into `work/modelserver.yaml` and applies the same public-image guard.
3. `kubectl apply`, then polls until all replicas are Ready. The default timeout is 60 minutes (`WAIT_MIN=90` to extend); the first load from GCS typically takes 10–30 minutes.

### Step B6: verify end to end
```bash
./scripts/60-verify.sh
```
From an in-cluster curl pod it runs `GET /v1/models`, one completion, and 10 requests that share a prefix, all through the Service `<release>-epp:80`. It then prints the last EPP log lines so you can see the routing decisions.

---

## 7. Troubleshooting (GAIE and router)

| Symptom | Cause | Fix |
|---|---|---|
| `helm` says `no matches for kind "InferencePool" in version "inference.networking.k8s.io/v1"` | CRD not installed | `30-install-gaie-crds.sh` |
| Step 30 says "managed by GKE" | GKE Inference Gateway installed its own CRD | Fine if it serves `v1` (the script checks). Don't fight the addon manager. |
| EPP pod `ImagePullBackOff`, event `403 Forbidden` | node SA can't read AR (or the repo is in another project) | grant `roles/artifactregistry.reader` to the node SA on that repo |
| `ImagePullBackOff`, event `i/o timeout` / `no such host` | no Private Google Access, or DNS for `*.pkg.dev` | enable PGA; fix the Cloud DNS private zone |
| `ImagePullBackOff`, `not found` | ref in `config.env` doesn't match what's in AR | `gcloud artifacts docker images list $AR` |
| `crane copy` → `DENIED` | pushing to a remote (read-only) repo | `MIRROR_MODE=remote` |
| EPP `CrashLoopBackOff`, logs mention `forbidden` | RBAC mismatch (release renamed / namespace changed by hand) | `kubectl auth can-i list inferencepools -n NS --as=system:serviceaccount:NS:RELEASE-epp`, then re-run step 40 |
| EPP `CrashLoopBackOff`, config parse error | edited plugin config | diff `kubectl get cm RELEASE-epp -o yaml` against `work/llm-d/guides/optimized-baseline/router/optimized-baseline.values.yaml` |
| Requests return 5xx / "no healthy upstream" | pool has no Ready pods | `kubectl get pods -l llm-d.ai/guide=optimized-baseline`, then wait for step 50 or fix vLLM |
| `404 model ... does not exist` | `model` in the request ≠ `--served-model-name` | send `MODEL_ID` exactly |
| vLLM pod stuck `ContainerCreating`, gcsfuse `PermissionDenied` | bucket IAM / Workload Identity | `45-grant-bucket-access.sh`; check the WI pool in preflight |
| vLLM logs try to reach `huggingface.co` | model path wrong, so vLLM falls back to the Hub | check `gs://BUCKET/MODEL_ID/config.json` exists |
| Load uneven / low cache-hit rate on non-H100 or another model | `peakPrefillThroughput` is calibrated for Qwen3-32B/H100/TP2 | run `work/llm-d/guides/recipes/router/calibration` and set it in the guide values |

Useful one-liners:
```bash
kubectl -n llm-d-optimized-baseline get events --sort-by=.lastTimestamp | tail -20
```
```bash
kubectl -n llm-d-optimized-baseline logs deploy/optimized-baseline-epp -c envoy-proxy --tail=50
```
```bash
kubectl -n llm-d-optimized-baseline get inferencepool optimized-baseline -o yaml
```

---

## 8. Uninstall
```bash
./scripts/90-uninstall.sh
```
This removes the model servers and the router release. Add `--crds` to also delete the InferencePool CRD, which **removes every InferencePool in the cluster**. The namespace is kept.

## 9. Not covered
- **Benchmarking** (`llmdbenchmark`): it needs pip and git access, so it needs separate offline packaging.
- **Monitoring stack** (Prometheus/Grafana): it has its own images to mirror. The router ServiceMonitor is supported via `MONITORING=1`.
- **Gateway mode** (GKE Gateway / Istio / agentgateway in front of the EPP): standalone mode is used instead.
