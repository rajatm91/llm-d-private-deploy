#!/usr/bin/env bash
# PRIVATE HOST (gcloud). Lets the model-server KSA read the model bucket via Workload Identity
# (direct principal binding, no GSA / annotation needed).
source "$(dirname "$0")/lib.sh"
need gcloud
num=$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')
member="principal://iam.googleapis.com/projects/${num}/locations/global/workloadIdentityPools/${PROJECT_ID}.svc.id.goog/subject/ns/${NAMESPACE}/sa/${MS_SA}"
log "Granting roles/storage.objectViewer on gs://$MODEL_BUCKET to $member"
gcloud storage buckets add-iam-policy-binding "gs://$MODEL_BUCKET" --member="$member" --role=roles/storage.objectViewer >/dev/null
gcloud storage ls "gs://$MODEL_BUCKET/$MODEL_ID/config.json" >/dev/null && ok "model found at gs://$MODEL_BUCKET/$MODEL_ID" \
  || warn "gs://$MODEL_BUCKET/$MODEL_ID/config.json not found; run 15-stage-model.sh"
