#!/usr/bin/env bash
# Build the arm64 ASA server image locally and push it to Docker Hub.
# Usage: ./build.sh            build only (loaded into local Docker)
#        ./build.sh --push     build, push to :2_1_experimental
#        ./build.sh --push TAG build, push to :TAG (e.g. for a test branch)
#        ./build.sh --release  promote :2_1_experimental to :2_1_latest (no rebuild)
#                              Do this after testing the experimental image on arm64.
set -euo pipefail
cd "$(dirname "$0")"

REPO=timk1299/asa_server_arm64
IMAGE=$REPO:2_1_latest
EXPERIMENTAL=$REPO:2_1_experimental
TEST_IMAGE=asa-test:arm64
CACHE_DIR=.buildx-cache

usage() {
  cat <<USAGE
Usage: $0 [OPTION]

Build the arm64 ASA server image locally.

Options:
  (none)       Build the image and load it as $TEST_IMAGE.
  --push [TAG] Build, then push to $EXPERIMENTAL,
               or to $REPO:TAG when a tag is given.
  --release    Promote $EXPERIMENTAL to $IMAGE
               without rebuilding. Do this after testing the experimental image
               on an arm64 machine.
  -h, --help   Show this help.

Layers are cached in $CACHE_DIR/ (delete it to force a full rebuild).
USAGE
}

case "${1:-}" in
  ""|--push|--release) ;;
  -h|--help) usage; exit 0 ;;
  *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
esac

if [[ "${1:-}" == "--release" ]]; then
  docker buildx imagetools create -t "$IMAGE" "$EXPERIMENTAL"
  echo "Released $EXPERIMENTAL as $IMAGE"
  exit 0
fi

# Persistent on-disk layer cache (mode=max also caches intermediate layers)
docker buildx build --platform linux/arm64 --progress=plain --load -t "$TEST_IMAGE" \
  --cache-from "type=local,src=$CACHE_DIR" \
  --cache-to "type=local,dest=$CACHE_DIR,mode=max" .

if [[ "${1:-}" == "--push" ]]; then
  PUSH_IMAGE=$EXPERIMENTAL
  [[ -n "${2:-}" ]] && PUSH_IMAGE=$REPO:$2
  # Rebuild is a full cache hit; this pushes the exact layers that were built above
  docker buildx build --platform linux/arm64 --push -t "$PUSH_IMAGE" \
    --cache-from "type=local,src=$CACHE_DIR" .
  echo "Pushed $PUSH_IMAGE"
else
  echo "Built $TEST_IMAGE. Test on an arm64 machine with: docker run -it $TEST_IMAGE"
fi
