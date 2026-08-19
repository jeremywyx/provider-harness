#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../local-xpkg-common.sh
source "$ROOT_DIR/hack/local-xpkg-common.sh"

[[ "$KIND_CLUSTER_NAME" == "provider-harness-dev" ]]
[[ "$KIND_NETWORK" == "kind" ]]
[[ "$PACKAGE_NAME" == "provider-harness" ]]
[[ "$PACKAGE_TAG" == "local" ]]
[[ "$PACKAGE_REPO" == "provider-harness:local" ]]
[[ "$REGISTRY_IMAGE" == "registry:3" ]]
[[ "$REGISTRY_CONTAINER" == "kind-registry" ]]
[[ "$REGISTRY_PORT" == "5000" ]]
[[ "$REGISTRY_HOST_PORT" == "5001" ]]
[[ "$PUSH_REGISTRY" == "127.0.0.1:5001" ]]
[[ "$PUSH_REF" == "127.0.0.1:5001/provider-harness:local" ]]
[[ "$CROSSPLANE_CLI_VERSION" == "v2.3.4" ]]
[[ "$CROSSPLANE_VERSION" == "2.3.4" ]]
[[ "$LOCAL_STATE_DIR" == "$ROOT_DIR/_output/local-xpkg" ]]
[[ "$HELM_CONFIG_HOME" == "$LOCAL_STATE_DIR/helm/config" ]]
[[ "$HELM_CACHE_HOME" == "$LOCAL_STATE_DIR/helm/cache" ]]
[[ "$HELM_DATA_HOME" == "$LOCAL_STATE_DIR/helm/data" ]]

assert_package_ref() {
  local expected="$1"
  local got
  got="$(REGISTRY_IP=172.18.0.3 bash -c 'source "$1"; package_ref' _ "$ROOT_DIR/hack/local-xpkg-common.sh")"
  [[ "$got" == "$expected" ]] || {
    printf 'package_ref: expected %q, got %q\n' "$expected" "$got" >&2
    exit 1
  }
}

assert_package_ref "172.18.0.3:5000/provider-harness:local"
assert_custom_package_ref() {
  local got
  got="$(REGISTRY_IP=192.168.1.10 REGISTRY_PORT=5000 PACKAGE_TAG=dev bash -c 'source "$1"; package_ref' _ "$ROOT_DIR/hack/local-xpkg-common.sh")"
  [[ "$got" == "192.168.1.10:5000/provider-harness:dev" ]] || {
    printf 'package_ref (custom): expected 192.168.1.10:5000/provider-harness:dev, got %q\n' "$got" >&2
    exit 1
  }
}
assert_custom_package_ref

assert_package_ref_rejected() {
  local package_ref="$1"
  local output
  if output="$(PACKAGE_REF="$package_ref" bash -c 'source "$1"; validate_package_ref "$PACKAGE_REF"' _ "$ROOT_DIR/hack/local-xpkg-common.sh" 2>&1)"; then
    printf 'unsafe PACKAGE_REF was accepted: %q\n%s\n' "$package_ref" "$output" >&2
    exit 1
  fi
  [[ "$output" == *"invalid PACKAGE_REF"* ]]
}

for package_ref in \
  "" \
  /leading \
  trailing/ \
  registry//provider:local \
  registry/./provider:local \
  registry/../provider:local \
  ../provider:local \
  registry/.. \
  'registry\\provider:local'; do
  assert_package_ref_rejected "$package_ref"
done

VALID_PACKAGE_REF="172.18.0.3:5000/provider-harness:local"
if ! PACKAGE_REF="$VALID_PACKAGE_REF" bash -c 'source "$1"; validate_package_ref "$PACKAGE_REF"' _ "$ROOT_DIR/hack/local-xpkg-common.sh"; then
  printf 'valid PACKAGE_REF was rejected: %q\n' "$VALID_PACKAGE_REF" >&2
  exit 1
fi

TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

run_state_command() {
  local state_dir="$1"
  shift
  LOCAL_STATE_DIR="$state_dir" bash -c 'source "$1"; shift; "$@"' _ \
    "$ROOT_DIR/hack/local-xpkg-common.sh" "$@"
}

NEW_STATE="$TEST_ROOT/new-state"
run_state_command "$NEW_STATE" ensure_local_state_dir
[[ "$(< "$NEW_STATE/.provider-harness-local-xpkg")" == "provider-harness-local-xpkg" ]]

EMPTY_STATE="$TEST_ROOT/empty-state"
mkdir "$EMPTY_STATE"
run_state_command "$EMPTY_STATE" ensure_local_state_dir
[[ "$(< "$EMPTY_STATE/.provider-harness-local-xpkg")" == "provider-harness-local-xpkg" ]]

MARKED_STATE="$TEST_ROOT/marked-state"
mkdir "$MARKED_STATE"
printf 'provider-harness-local-xpkg\n' > "$MARKED_STATE/.provider-harness-local-xpkg"
run_state_command "$MARKED_STATE" ensure_local_state_dir

assert_state_rejected() {
  local state_dir="$1"
  local output
  if output="$(LOCAL_STATE_DIR="$state_dir" bash -c 'source "$1"; ensure_local_state_dir' _ "$ROOT_DIR/hack/local-xpkg-common.sh" 2>&1)"; then
    printf 'unsafe LOCAL_STATE_DIR was accepted: %s\n%s\n' "$state_dir" "$output" >&2
    exit 1
  fi
  [[ "$output" == *"LOCAL_STATE_DIR"* || "$output" == *"path contains symlink component"* ]]
}

mkdir "$TEST_ROOT/non-dedicated"
: > "$TEST_ROOT/non-dedicated/unrelated"
assert_state_rejected "$TEST_ROOT/non-dedicated"

mkdir "$TEST_ROOT/wrong-marker"
printf 'not-provider-harness\n' > "$TEST_ROOT/wrong-marker/.provider-harness-local-xpkg"
assert_state_rejected "$TEST_ROOT/wrong-marker"

mkdir "$TEST_ROOT/symlink-target"
ln -s "$TEST_ROOT/symlink-target" "$TEST_ROOT/state-link"
assert_state_rejected "$TEST_ROOT/state-link"

mkdir "$TEST_ROOT/parent-target"
ln -s "$TEST_ROOT/parent-target" "$TEST_ROOT/parent-link"
assert_state_rejected "$TEST_ROOT/parent-link/state"

assert_state_rejected "/"
assert_state_rejected "$ROOT_DIR"
assert_state_rejected "$(dirname "$ROOT_DIR")"

mkdir "$TEST_ROOT/helm-target"
assert_state_rejected "$TEST_ROOT/helm-target/../helm-target"

if output="$(LOCAL_STATE_DIR="$TEST_ROOT/helm-state" HELM_CONFIG_HOME="$TEST_ROOT/helm-state/helm-link/config" bash -c 'mkdir -p "$1"; ln -s "$2" "$1/helm-link"; source "$3"' _ "$TEST_ROOT/helm-state" "$TEST_ROOT/helm-target" "$ROOT_DIR/hack/local-xpkg-common.sh" 2>&1)"; then
  printf 'symlinked Helm path was accepted: %s\n' "$output" >&2
  exit 1
fi
[[ "$output" == *"HELM_CONFIG_HOME"* ]]

if output="$(LOCAL_STATE_DIR="$ROOT_DIR/_output/local-xpkg" HELM_CONFIG_HOME="$HOME/.config/helm" bash -c 'source "$1"' _ "$ROOT_DIR/hack/local-xpkg-common.sh" 2>&1)"; then
  printf 'global HELM_CONFIG_HOME override was accepted: %s\n' "$output" >&2
  exit 1
fi
[[ "$output" == *"HELM_CONFIG_HOME must be under LOCAL_STATE_DIR"* ]]

if output="$(HOST_PLATFORM=freebsd_amd64 bash -c 'source "$1"' _ "$ROOT_DIR/hack/local-xpkg-common.sh" 2>&1)"; then
  printf 'unsupported HOST_PLATFORM override was accepted: %s\n' "$output" >&2
  exit 1
fi
[[ "$output" == *"unsupported host platform: freebsd_amd64"* ]]

printf 'local-xpkg-common contract: PASS\n'
