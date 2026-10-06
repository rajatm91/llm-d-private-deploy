#!/usr/bin/env bash
# PRIVATE HOST (inside the VPC, kubectl access to the cluster). Read-only checks except
# short-lived pull-test pods. Set PULL_TEST_VLLM=1 to also pull the ~10 GB vLLM image on a GPU node.
source "$(dirname "$0")/lib.sh"
need kubectl helm gcloud tar
fail=0; bad() { warn "$*"; fail=1; }

log "1/7 Bundle integrity"
[[ -f $BUNDLE/SHA256SUMS ]] || die "no bundle/SHA256SUMS; copy the bundle from 10-bundle.sh"
(cd "$BUNDLE" && sha -c SHA256SUMS >/dev/null) && ok "checksums match" || bad "checksum mismatch"
ensure_src

log "2/7 Cluster access"
kubectl version -o yaml >/dev/null 2>&1 || die "kubectl cannot reach the API server (context: $(kubectl config current-context 2>/dev/null))"
ok "context: $(kubectl config current-context)"
kubectl auth can-i create customresourcedefinitions >/dev/null && ok "can create CRDs" || bad "no permission to create CRDs (need cluster-admin for step 30)"

log "3/7 GPU capacity (need $((REPLICAS*TP)) x nvidia.com/gpu)"
gpus=$(kubectl get nodes -o jsonpath='{range .items[*]}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}' | awk '{s+=$1} END {print s+0}')
kubectl get nodes -L cloud.google.com/gke-accelerator,cloud.google.com/gke-nodepool | awk 'NR==1 || $6!=""'
(( gpus >= REPLICAS*TP )) && ok "$gpus GPUs allocatable" || bad "only $gpus GPUs allocatable; lower REPLICAS or add nodes"

log "4/7 GKE add-ons"
kubectl get csidriver gcsfuse.csi.storage.gke.io >/dev/null 2>&1 && ok "GCS FUSE CSI driver installed" \
  || bad "GCS FUSE CSI driver missing: gcloud container clusters update $CLUSTER_NAME --location $CLUSTER_LOCATION --update-addons GcsFuseCsiDriver=ENABLED"
if [[ -n $CLUSTER_NAME ]]; then
  pool=$(gcloud container clusters describe "$CLUSTER_NAME" --location "$CLUSTER_LOCATION" --project "$PROJECT_ID" --format='value(workloadIdentityConfig.workloadPool)' 2>/dev/null || true)
  [[ -n $pool ]] && ok "Workload Identity pool: $pool" || bad "Workload Identity not enabled (or cluster describe failed)"
fi

log "5/7 Existing state"
if kubectl get crd inferencepools.inference.networking.k8s.io >/dev/null 2>&1; then
  warn "InferencePool CRD already present (versions: $(kubectl get crd inferencepools.inference.networking.k8s.io -o jsonpath='{.spec.versions[*].name}')); step 30 will reconcile it"
else ok "InferencePool CRD not installed yet"; fi
helm status "$RELEASE" -n "$NAMESPACE" >/dev/null 2>&1 && warn "helm release $RELEASE exists in $NAMESPACE; step 40 upgrades it" || ok "no existing release"

log "6/7 Images in Artifact Registry"
for img in "$VLLM_IMAGE" "$EPP_IMAGE" "$ENVOY_IMAGE" "$CURL_IMAGE"; do
  d=$(gcloud artifacts docker images describe "$img" --format='value(image_summary.digest)' 2>/dev/null || true)
  [[ -n $d ]] && ok "$img  $d" || bad "not found in AR: $img"
done

log "7/7 In-cluster pull test (proves node SA + Private Google Access reach AR)"
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
pull_test() { # name image [overrides-json]
  local name=pulltest-$1 img=$2 ov=${3:-}
  kubectl -n "$NAMESPACE" delete pod "$name" --ignore-not-found --wait=false >/dev/null
  kubectl -n "$NAMESPACE" run "$name" --image="$img" --restart=Never ${ov:+--overrides="$ov"} >/dev/null
  for _ in $(seq 1 ${4:-60}); do
    id=$(kubectl -n "$NAMESPACE" get pod "$name" -o jsonpath='{.status.containerStatuses[0].imageID}' 2>/dev/null || true)
    why=$(kubectl -n "$NAMESPACE" get pod "$name" -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null || true)
    if [[ -n $id ]]; then ok "pulled $img"; break; fi
    if [[ $why == ErrImagePull || $why == ImagePullBackOff || $why == InvalidImageName ]]; then
      bad "$why for $img: $(kubectl -n "$NAMESPACE" get events --field-selector involvedObject.name="$name" -o jsonpath='{.items[-1:].message}')"; break
    fi
    sleep 5
  done
  [[ -n $id || -n $why ]] || bad "timeout pulling $img"
  kubectl -n "$NAMESPACE" delete pod "$name" --ignore-not-found --wait=false >/dev/null
}
pull_test epp "$EPP_IMAGE"
pull_test envoy "$ENVOY_IMAGE"
pull_test curl "$CURL_IMAGE"
if [[ ${PULL_TEST_VLLM:-0} == 1 ]]; then
  # lands on any GPU node (GKE labels them cloud.google.com/gke-accelerator) so the image is cached there
  pull_test vllm "$VLLM_IMAGE" '{"spec":{"tolerations":[{"key":"nvidia.com/gpu","operator":"Exists","effect":"NoSchedule"}],"affinity":{"nodeAffinity":{"requiredDuringSchedulingIgnoredDuringExecution":{"nodeSelectorTerms":[{"matchExpressions":[{"key":"cloud.google.com/gke-accelerator","operator":"Exists"}]}]}}}}}' 360
fi

(( fail == 0 )) && log "Preflight passed" || die "Preflight found problems (see ! lines above)"
