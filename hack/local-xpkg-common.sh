#!/usr/bin/env bash

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log() {
  printf '[local-xpkg] %s\n' "$*"
}

fail() {
  printf '[local-xpkg] ERROR: %s\n' "$*" >&2
  exit 1
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    fail "required command not found: $1"
  fi
}

PROJECT_NAME="${PROJECT_NAME:-provider-harness}"
KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME:-provider-harness-dev}"
KIND_NETWORK="${KIND_NETWORK:-kind}"
CROSSPLANE_NAMESPACE="${CROSSPLANE_NAMESPACE:-crossplane-system}"
PACKAGE_NAME="${PACKAGE_NAME:-$PROJECT_NAME}"
PACKAGE_TAG="${PACKAGE_TAG:-local}"
PACKAGE_REPO="${PACKAGE_REPO:-$PACKAGE_NAME:$PACKAGE_TAG}"
REGISTRY_IMAGE="${REGISTRY_IMAGE:-registry:3}"
REGISTRY_CONTAINER="${REGISTRY_CONTAINER:-kind-registry}"
REGISTRY_PORT="${REGISTRY_PORT:-5000}"
REGISTRY_HOST_PORT="${REGISTRY_HOST_PORT:-5001}"
PUSH_REGISTRY="${PUSH_REGISTRY:-127.0.0.1:$REGISTRY_HOST_PORT}"
PUSH_REF="${PUSH_REF:-$PUSH_REGISTRY/$PACKAGE_REPO}"
TAG="${TAG:-$(git describe --always --dirty 2>/dev/null || printf dev)}"
XPKG_OUTPUT_DIR="${XPKG_OUTPUT_DIR:-$ROOT_DIR/_output/xpkg}"
LOCAL_STATE_DIR="${LOCAL_STATE_DIR:-$ROOT_DIR/_output/local-xpkg}"
HELM_CONFIG_HOME="${HELM_CONFIG_HOME:-$LOCAL_STATE_DIR/helm/config}"
HELM_CACHE_HOME="${HELM_CACHE_HOME:-$LOCAL_STATE_DIR/helm/cache}"
HELM_DATA_HOME="${HELM_DATA_HOME:-$LOCAL_STATE_DIR/helm/data}"
CROSSPLANE_CLI_VERSION="${CROSSPLANE_CLI_VERSION:-v2.3.4}"
CROSSPLANE_VERSION="${CROSSPLANE_VERSION:-2.3.4}"
LOCAL_STATE_MARKER_VALUE="provider-harness-local-xpkg"
LOCAL_STATE_MARKER_FILE="$LOCAL_STATE_DIR/.provider-harness-local-xpkg"

REGISTRY_IP="${REGISTRY_IP:-}"

validate_package_ref() {
  local package_ref="$1"
  local remainder="$package_ref"
  local segment

  if [[ -z "$package_ref" || ! "$package_ref" =~ ^[A-Za-z0-9._:@/-]+$ ]]; then
    fail "invalid PACKAGE_REF: $package_ref"
  fi
  if [[ "$package_ref" == /* ]]; then
    fail "invalid PACKAGE_REF with leading slash: $package_ref"
  fi

  while [[ "$remainder" == */* ]]; do
    segment="${remainder%%/*}"
    if [[ -z "$segment" || "$segment" == "." || "$segment" == ".." ]]; then
      fail "invalid PACKAGE_REF path segment: $package_ref"
    fi
    remainder="${remainder#*/}"
  done
  if [[ -z "$remainder" || "$remainder" == "." || "$remainder" == ".." ]]; then
    fail "invalid PACKAGE_REF path segment: $package_ref"
  fi
}

reject_symlink_components() {
  local path="$1"
  local current="/"
  local remainder="${path#/}"
  local component

  while [[ -n "$remainder" ]]; do
    component="${remainder%%/*}"
    if [[ "$remainder" == */* ]]; then
      remainder="${remainder#*/}"
    else
      remainder=""
    fi
    if [[ "$current" == "/" ]]; then
      current="/$component"
    else
      current="$current/$component"
    fi
    if [[ -L "$current" ]]; then
      case "$current" in
        /tmp|/var)
          # macOS exposes these stable system locations as symlinks.
          ;;
        *)
          fail "path contains symlink component: $path"
          ;;
      esac
    fi
  done
}

validate_local_state_dir_path() {
  local repository_parent

  if [[ -z "$LOCAL_STATE_DIR" || "$LOCAL_STATE_DIR" != /* ]]; then
    fail "LOCAL_STATE_DIR must be an absolute path: $LOCAL_STATE_DIR"
  fi
  if [[ "$LOCAL_STATE_DIR" == "/" || "$LOCAL_STATE_DIR" == *"//"* || "$LOCAL_STATE_DIR" == */ ]]; then
    fail "LOCAL_STATE_DIR is not a dedicated directory: $LOCAL_STATE_DIR"
  fi
  case "$LOCAL_STATE_DIR" in
    *"/./"*|*/.|*"/../"*|*/..|../*|.|..)
      fail "LOCAL_STATE_DIR must not contain traversal segments: $LOCAL_STATE_DIR"
      ;;
  esac

  repository_parent="$(dirname "$ROOT_DIR")"
  if [[ "$LOCAL_STATE_DIR" == "$ROOT_DIR" || "$LOCAL_STATE_DIR" == "$repository_parent" ]]; then
    fail "LOCAL_STATE_DIR must not be the repository root or parent: $LOCAL_STATE_DIR"
  fi
  reject_symlink_components "$LOCAL_STATE_DIR"
  if [[ -e "$LOCAL_STATE_DIR" && ! -d "$LOCAL_STATE_DIR" ]]; then
    fail "LOCAL_STATE_DIR is not a directory: $LOCAL_STATE_DIR"
  fi
}

state_marker_is_valid() {
  [[ -f "$LOCAL_STATE_MARKER_FILE" && ! -L "$LOCAL_STATE_MARKER_FILE" ]] || return 1
  [[ "$(< "$LOCAL_STATE_MARKER_FILE")" == "$LOCAL_STATE_MARKER_VALUE" ]]
}

ensure_local_state_dir() {
  local entry

  validate_local_state_dir_path
  if [[ -e "$LOCAL_STATE_DIR" ]]; then
    if ! [[ -d "$LOCAL_STATE_DIR" && ! -L "$LOCAL_STATE_DIR" ]]; then
      fail "LOCAL_STATE_DIR is not a dedicated directory: $LOCAL_STATE_DIR"
    fi
  else
    mkdir -p "$LOCAL_STATE_DIR"
  fi

  if [[ -e "$LOCAL_STATE_MARKER_FILE" || -L "$LOCAL_STATE_MARKER_FILE" ]]; then
    state_marker_is_valid || fail "LOCAL_STATE_DIR marker is invalid: $LOCAL_STATE_MARKER_FILE"
    return
  fi

  for entry in "$LOCAL_STATE_DIR"/* "$LOCAL_STATE_DIR"/.[!.]* "$LOCAL_STATE_DIR"/..?*; do
    [[ -e "$entry" || -L "$entry" ]] || continue
    fail "LOCAL_STATE_DIR is not a dedicated directory: $LOCAL_STATE_DIR"
  done
  printf '%s\n' "$LOCAL_STATE_MARKER_VALUE" > "$LOCAL_STATE_MARKER_FILE"
}

require_local_state_marker() {
  validate_local_state_dir_path
  if [[ ! -e "$LOCAL_STATE_DIR" && ! -L "$LOCAL_STATE_DIR" ]]; then
    return
  fi
  state_marker_is_valid || fail "LOCAL_STATE_DIR marker is invalid: $LOCAL_STATE_MARKER_FILE"
}

require_local_state_path() {
  local variable_name="$1"
  local path="$2"

  case "$path" in
    "$LOCAL_STATE_DIR"/*)
      ;;
    *)
      fail "$variable_name must be under LOCAL_STATE_DIR ($LOCAL_STATE_DIR): $path"
      ;;
  esac
  if [[ "$path" == *"/../"* || "$path" == */.. ]]; then
    fail "$variable_name must not escape LOCAL_STATE_DIR: $path"
  fi
  if [[ "$path" == *"//"* || "$path" == */ || "$path" == *"/./"* || "$path" == */. ]]; then
    fail "$variable_name must be a clean path under LOCAL_STATE_DIR: $path"
  fi
  reject_symlink_components "$path"
}

validate_local_state_dir_path
require_local_state_path HELM_CONFIG_HOME "$HELM_CONFIG_HOME"
require_local_state_path HELM_CACHE_HOME "$HELM_CACHE_HOME"
require_local_state_path HELM_DATA_HOME "$HELM_DATA_HOME"

if [[ -z "${HOST_PLATFORM:-}" ]]; then
  case "$(uname -s):$(uname -m)" in
    Darwin:x86_64|Darwin:amd64)
      HOST_PLATFORM="darwin_amd64"
      ;;
    Darwin:arm64|Darwin:aarch64)
      HOST_PLATFORM="darwin_arm64"
      ;;
    Linux:x86_64|Linux:amd64)
      HOST_PLATFORM="linux_amd64"
      ;;
    Linux:arm64|Linux:aarch64)
      HOST_PLATFORM="linux_arm64"
      ;;
    *)
      fail "unsupported host platform: $(uname -s)/$(uname -m)"
      ;;
  esac
fi

case "$HOST_PLATFORM" in
  darwin_amd64|darwin_arm64|linux_amd64|linux_arm64)
    ;;
  *)
    fail "unsupported host platform: $HOST_PLATFORM"
    ;;
esac

CROSSPLANE_CLI="$LOCAL_STATE_DIR/bin/crossplane-cli-$CROSSPLANE_CLI_VERSION"
XPKG_FILE="$XPKG_OUTPUT_DIR/$PACKAGE_NAME-$TAG.xpkg"
PACKAGE_ROOT="${PACKAGE_ROOT:-$ROOT_DIR/package}"
EXAMPLES_ROOT="${EXAMPLES_ROOT:-$ROOT_DIR/examples}"

# registry_ip prints the kind-network IP of the local registry container.
# Prefer a caller-supplied REGISTRY_IP so the address can be reused without
# re-querying Docker (e.g. during cleanup after the registry is gone).
registry_ip() {
  if [[ -z "$REGISTRY_IP" ]]; then
    require_command docker
    REGISTRY_IP="$(docker inspect --format "{{.NetworkSettings.Networks.$KIND_NETWORK.IPAddress}}" "$REGISTRY_CONTAINER" 2>/dev/null || true)"
  fi
  [[ -n "$REGISTRY_IP" ]] || fail "local registry not found: $REGISTRY_CONTAINER (run ensure_registry first)"
  printf '%s\n' "$REGISTRY_IP"
}

# ensure_registry creates/starts the local registry container, wires it onto the
# kind network, and prints the in-cluster registry address (RFC1918, plain HTTP).
ensure_registry() {
  require_command docker
  if ! docker ps --format '{{.Names}}' | grep -qx "$REGISTRY_CONTAINER"; then
    docker run -d --restart=always \
      -p "127.0.0.1:$REGISTRY_HOST_PORT:$REGISTRY_PORT" \
      --name "$REGISTRY_CONTAINER" \
      "$REGISTRY_IMAGE" >/dev/null
  fi

  local ip
  ip="$(docker inspect --format "{{.NetworkSettings.Networks.$KIND_NETWORK.IPAddress}}" "$REGISTRY_CONTAINER" 2>/dev/null || true)"
  if [[ -z "$ip" ]]; then
    docker network connect "$KIND_NETWORK" "$REGISTRY_CONTAINER"
    ip="$(docker inspect --format "{{.NetworkSettings.Networks.$KIND_NETWORK.IPAddress}}" "$REGISTRY_CONTAINER" 2>/dev/null || true)"
  fi
  [[ -n "$ip" ]] || fail "local registry is not attached to the kind network: $KIND_NETWORK"
  REGISTRY_IP="$ip"
  printf '%s\n' "$REGISTRY_IP"
}

# package_ref prints the fully qualified in-cluster package reference, e.g.
# 172.18.0.3:5000/provider-harness:local. go-containerregistry treats the RFC1918
# private IP as an insecure registry and uses plain HTTP automatically.
package_ref() {
  local ip
  ip="$(registry_ip)"
  printf '%s:%s/%s\n' "$ip" "$REGISTRY_PORT" "$PACKAGE_REPO"
}

# loaded_image_id loads a local OCI image archive and prints the resulting image
# identifier (tag or digest) as reported by `docker load`.
loaded_image_id() {
  local archive="$1"
  local output loaded
  output="$(docker load --input "$archive" 2>&1)"
  loaded=""
  if [[ "$output" =~ Loaded[[:space:]]image[[:space:]]ID:[[:space:]](sha256:[^[:space:]]+) ]]; then
    loaded="${BASH_REMATCH[1]}"
  elif [[ "$output" =~ Loaded[[:space:]]image:[[:space:]]([^[:space:]]+) ]]; then
    loaded="${BASH_REMATCH[1]}"
  fi
  [[ -n "$loaded" ]] || fail "docker load did not report an image identifier: $output"
  printf '%s\n' "$loaded"
}
