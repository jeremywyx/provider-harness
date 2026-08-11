#!/usr/bin/env bash
set -euo pipefail

# Builds the provider container image with docker buildx.
# All settings come from env vars so the org pipeline can point the build
# at private registries without editing this file.
#
#   REGISTRY        target image registry/org, e.g. harbor.corp.com/harness (default: local)
#   IMAGE_NAME      image name (default: provider-harness)
#   TAG             image tag (default: git describe --always --dirty)
#   PLATFORMS       build platforms (default: linux/amd64,linux/arm64)
#   BASE_REGISTRY   registry hosting golang/distroless base images (default: gcr.io)
#   GOPROXY         Go module proxy (default: https://proxy.golang.org,direct)
#   GOSUMDB         Go checksum db (default: sum.golang.org)
#   GONOSUMDB       comma-separated module paths exempt from the checksum db
#   MODULE_PATH     Go module path for the -X version ldflag (default: current module)
#   VERSION         version baked into the binary (default: $TAG)
#   BUILD_ARGS      extra docker buildx args, e.g. "--push" (default: --load)
#
#   NOTE: building for non-native architectures (e.g. linux/arm64 on an amd64
#   host) requires QEMU/binfmt emulation on the build host.

REGISTRY=${REGISTRY:-local}
IMAGE_NAME=${IMAGE_NAME:-provider-harness}
TAG=${TAG:-$(git describe --always --dirty 2>/dev/null || echo dev)}
PLATFORMS=${PLATFORMS:-linux/amd64,linux/arm64}
BASE_REGISTRY=${BASE_REGISTRY:-gcr.io}
GOPROXY=${GOPROXY:-https://proxy.golang.org,direct}
GOSUMDB=${GOSUMDB:-sum.golang.org}
GONOSUMDB=${GONOSUMDB:-""}
MODULE_PATH=${MODULE_PATH:-$(go list -m 2>/dev/null || echo github.com/jeremywyx/provider-harness)}
VERSION=${VERSION:-$TAG}
BUILD_ARGS=${BUILD_ARGS:---load}

# docker buildx cannot export multi-platform manifests with --load.
if [[ "${BUILD_ARGS}" == *"--load"* ]] && [[ "${PLATFORMS}" == *","* ]]; then
	echo "error: BUILD_ARGS=--load cannot be combined with multiple PLATFORMS (docker buildx cannot export a manifest list with --load)." >&2
	echo "Set PLATFORMS to a single platform (e.g. PLATFORMS=linux/amd64) or use BUILD_ARGS=--push." >&2
	exit 1
fi

IMAGE_REF="${REGISTRY}/${IMAGE_NAME}:${TAG}"

docker buildx build ${BUILD_ARGS} \
  --platform "${PLATFORMS}" \
  -t "${IMAGE_REF}" \
  --build-arg BASE_REGISTRY="${BASE_REGISTRY}" \
  --build-arg GOPROXY="${GOPROXY}" \
  --build-arg GOSUMDB="${GOSUMDB}" \
  --build-arg GONOSUMDB="${GONOSUMDB}" \
  --build-arg MODULE_PATH="${MODULE_PATH}" \
  --build-arg VERSION="${VERSION}" \
  -f Dockerfile .

echo "Built ${IMAGE_REF}"
