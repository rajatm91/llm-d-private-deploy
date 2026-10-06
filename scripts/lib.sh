# Sourced by every step script.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck disable=SC1090
source "${CONFIG:-$ROOT/config.env}"
BUNDLE=$ROOT/bundle
WORK=$ROOT/work
SRC=$WORK/llm-d                       # extracted llm-d source at ${LLMD_REF}
GUIDE=$SRC/guides/optimized-baseline
MS_SA=optimized-baseline-nvidia-gpu-vllm-sa
MS_DEPLOY=optimized-baseline-nvidia-gpu-vllm-decode

log()  { printf '\033[1;34m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
ok()   { printf '\033[1;32m  ✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  ! %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %b\n' "$*" >&2; exit 1; }
need() { for c; do command -v "$c" >/dev/null || die "missing tool: $c"; done; }
sha()  { if command -v sha256sum >/dev/null; then sha256sum "$@"; else shasum -a 256 "$@"; fi; }

# "host/path/repo:tag" -> "host/path repo tag" (tags only, not digests)
split_image() {
  local ref=$1 rest
  [[ $ref == *@* ]] && die "digest refs not supported here: $ref"
  rest=${ref##*/}
  echo "${ref%/*} ${rest%%:*} ${rest##*:}"
}

# Fail if rendered manifests still reference a public registry.
assert_no_public_images() {
  local bad
  bad=$(grep -E '^\s*image:' "$1" | grep -E 'docker\.io|ghcr\.io|quay\.io|registry\.k8s\.io|cr\.agentgateway\.dev' || true)
  [[ -z $bad ]] || die "public image refs left in $1:\n$bad"
  ok "all images in $(basename "$1") point at private registry:"
  grep -E '^\s*image:' "$1" | sort -u | sed 's/^ */      /'
}

ensure_src() {
  [[ -f $GUIDE/router/optimized-baseline.values.yaml ]] && return
  local tgz=$BUNDLE/llm-d-${LLMD_REF}.tar.gz
  [[ -f $tgz ]] || die "missing $tgz; run 10-bundle.sh on the connected host"
  mkdir -p "$SRC" && tar -xzf "$tgz" -C "$SRC" --strip-components=1
  ok "extracted llm-d ${LLMD_REF} to $SRC"
}
