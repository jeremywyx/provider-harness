#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=local-xpkg-common.sh
source "$ROOT_DIR/hack/local-xpkg-common.sh"

REGISTRY="${REGISTRY:-local}"
IMAGE_NAME="${IMAGE_NAME:-$PROJECT_NAME}"
PLATFORMS="${PLATFORMS:-linux/amd64}"
CONTROLLER_IMAGE="${CONTROLLER_IMAGE:-${REGISTRY}/${IMAGE_NAME}:${TAG}}"

require_command docker
ensure_local_state_dir
mkdir -p "$XPKG_OUTPUT_DIR" "$(dirname "$CROSSPLANE_CLI")"

if [[ ! -x "$CROSSPLANE_CLI" ]]; then
  require_command curl
  CLI_URL="https://cli.crossplane.io/stable/${CROSSPLANE_CLI_VERSION}/bin/${HOST_PLATFORM}/crossplane"
  curl -fsSLo "$CROSSPLANE_CLI" "$CLI_URL"
  chmod +x "$CROSSPLANE_CLI"
fi
[[ -x "$CROSSPLANE_CLI" ]] || fail "Crossplane CLI is not executable: $CROSSPLANE_CLI"

[[ -d "$PACKAGE_ROOT" ]] || fail "package root does not exist: $PACKAGE_ROOT"
[[ -d "$EXAMPLES_ROOT" ]] || fail "examples root does not exist: $EXAMPLES_ROOT"

REGISTRY="$REGISTRY" \
IMAGE_NAME="$IMAGE_NAME" \
TAG="$TAG" \
PLATFORMS="$PLATFORMS" \
BUILD_ARGS="--load" \
  "$ROOT_DIR/hack/build-image.sh"

"$CROSSPLANE_CLI" xpkg build \
  --embed-runtime-image="$CONTROLLER_IMAGE" \
  --package-root="$PACKAGE_ROOT" \
  --examples-root="$EXAMPLES_ROOT" \
  --package-file="$XPKG_FILE"
[[ -f "$XPKG_FILE" ]] || fail "Crossplane CLI did not create xpkg: $XPKG_FILE"

LOADED_IMAGE="$(loaded_image_id "$XPKG_FILE")"
ensure_registry
docker tag "$LOADED_IMAGE" "$PUSH_REF"
docker push "$PUSH_REF"

PACKAGE_REF="$(package_ref)"
validate_package_ref "$PACKAGE_REF"
printf '%s\n' "$PACKAGE_REF" > "$LOCAL_STATE_DIR/packageref"
printf '%s\n' "$REGISTRY_IP" > "$LOCAL_STATE_DIR/registry-ip"

printf 'XPKG_FILE=%s\n' "$XPKG_FILE"
printf 'PUSH_REF=%s\n' "$PUSH_REF"
printf 'PACKAGE_REF=%s\n' "$PACKAGE_REF"
