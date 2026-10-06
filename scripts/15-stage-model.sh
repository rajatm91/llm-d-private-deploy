#!/usr/bin/env bash
# CONNECTED HOST. Downloads ${MODEL_ID} from Hugging Face and syncs it to gs://${MODEL_BUCKET}/${MODEL_ID}.
# Needs: hf (pip install -U huggingface_hub), gcloud. Set HF_TOKEN for gated models. ~65 GB for Qwen3-32B.
source "$(dirname "$0")/lib.sh"
need hf gcloud
dir=${MODEL_DIR:-$WORK/models/$MODEL_ID}
log "Downloading $MODEL_ID -> $dir"
hf download "$MODEL_ID" --local-dir "$dir"
log "Syncing to gs://$MODEL_BUCKET/$MODEL_ID"
gcloud storage rsync -r "$dir" "gs://$MODEL_BUCKET/$MODEL_ID" --exclude='^\.cache/'
gcloud storage ls "gs://$MODEL_BUCKET/$MODEL_ID/config.json" >/dev/null && ok "config.json present"
