#!/usr/bin/env bash
# Build the multi-arch mpd-runtime image on macOS (Apple container) and
# publish it to ghcr.io. Bump TAG, commit, run. Tags are never re-pushed.
#
# NOTE: it is necessary to `container registry login ghcr.io` first

set -euo pipefail
# Run from assets/runtime/ whatever the caller's cwd: the build context
# "." and the Containerfile path below are relative to this directory.
cd "$(dirname "$0")"

IMAGE="${IMAGE:-ghcr.io/mutms/mpd-runtime}"
TAG="13.6.1"

if [ -n "$(git status --porcelain)" ]; then
    echo "error: working tree is not clean — commit or stash first" >&2
    exit 1
fi

echo "publishing $IMAGE:$TAG"

container build --arch arm64 --arch amd64 --build-arg VERSION="$TAG" -t "$IMAGE:$TAG" -f Containerfile .
container image push "$IMAGE:$TAG"

echo "published $IMAGE:$TAG"
