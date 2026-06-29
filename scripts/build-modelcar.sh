#!/usr/bin/env bash
# Build + push an OCI modelcar (weights-in-image) for KServe, and print the @sha256 digest to pin
# in the InferenceService (ADR-0016). This is the generic Docker path and the forker's tool for
# packaging their own (possibly large) model — args are HF model id + the target OCI image ref.
#
#   ./scripts/build-modelcar.sh Qwen/Qwen2.5-0.5B-Instruct <region>-docker.pkg.dev/<proj>/<repo>/qwen2.5-0.5b:v1
#
# No local Docker daemon? Use serving/kserve/modelcar/cloudbuild.yaml (GCP Cloud Build), or swap the
# `docker build`/`push` below for kaniko (`gcr.io/kaniko-project/executor`) or rootless podman —
# the Dockerfile and data/ layout are tool-agnostic.
#
# Requires: huggingface-cli (pip install "huggingface_hub[cli]"), docker, an authenticated push
# target (e.g. `gcloud auth configure-docker <region>-docker.pkg.dev`).
#
# Make it executable: chmod +x scripts/build-modelcar.sh
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: $0 <hf-model-id> <image-ref:tag>" >&2
  exit 1
fi

MODEL="$1"
IMAGE="$2"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODELCAR_DIR="$SCRIPT_DIR/../serving/kserve/modelcar"
DATA_DIR="$MODELCAR_DIR/data"

cleanup() { rm -rf "$DATA_DIR"; }
trap cleanup EXIT

# Stage weights into data/ (Dockerfile COPYs data/ -> /models). Exclude duplicate PyTorch
# checkpoints + the original/ dir; vLLM serves the safetensors and the extras only bloat the layer
# (= node image-disk + first-pull latency).
rm -rf "$DATA_DIR"
python3 -c "from huggingface_hub import snapshot_download; snapshot_download('$MODEL', local_dir='$DATA_DIR', ignore_patterns=['*.pt','*.pth','original/*'])"

docker build -t "$IMAGE" "$MODELCAR_DIR"
docker push "$IMAGE"

# Resolve and print the immutable digest to pin in the ISVC's storageUri.
DIGEST="$(docker inspect --format='{{index .RepoDigests 0}}' "$IMAGE")"
echo
echo "pushed: $IMAGE"
echo "pin this digest as the STORAGE_URI env in serving/kserve/inferenceservice-modelcar.yaml:"
echo "  - name: STORAGE_URI"
echo "    value: oci://$DIGEST"
