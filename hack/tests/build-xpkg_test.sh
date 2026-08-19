#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

FAKE_BIN="$TEST_ROOT/bin"
FAKE_LOG="$TEST_ROOT/commands.log"
FIRST_OUTPUT="$TEST_ROOT/first-output.log"
SECOND_OUTPUT="$TEST_ROOT/second-output.log"
INVALID_OUTPUT="$TEST_ROOT/invalid-output.log"
mkdir -p "$FAKE_BIN"
: > "$FAKE_LOG"

EXPECTED_PUSH_REF="127.0.0.1:5001/provider-harness:local"
EXPECTED_PACKAGE_REF="172.18.0.3:5000/provider-harness:local"

printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'printf "curl" >> "$FAKE_LOG"' \
  'printf " %s" "$@" >> "$FAKE_LOG"' \
  'printf "\\n" >> "$FAKE_LOG"' \
  '[[ "$1" == "-fsSLo" ]]' \
  'cp "$FAKE_BIN/crossplane" "$2"' \
  > "$FAKE_BIN/curl"
chmod +x "$FAKE_BIN/curl"

printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'printf "crossplane" >> "$FAKE_LOG"' \
  'printf " %s" "$@" >> "$FAKE_LOG"' \
  'printf "\\n" >> "$FAKE_LOG"' \
  '[[ "${1:-}" == "xpkg" && "${2:-}" == "build" ]]' \
  'package_file=' \
  'for arg in "$@"; do' \
  '  case "$arg" in' \
  '    --package-file=*) package_file="${arg#*=}" ;;' \
  '  esac' \
  'done' \
  '[[ -n "$package_file" ]]' \
  'mkdir -p "$(dirname "$package_file")"' \
  ': > "$package_file"' \
  > "$FAKE_BIN/crossplane"
chmod +x "$FAKE_BIN/crossplane"

printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'printf "docker" >> "$FAKE_LOG"' \
  'printf " %s" "$@" >> "$FAKE_LOG"' \
  'printf "\\n" >> "$FAKE_LOG"' \
  'case "${1:-}" in' \
  '  buildx)' \
  '    [[ "${2:-}" == "build" ]]' \
  '    ;;' \
  '  load)' \
  '    [[ "${2:-}" == "--input" ]]' \
  '    [[ -f "$3" ]]' \
  '    case "${DOCKER_LOAD_MODE:-id}" in' \
  '      id)' \
  '        printf "Loaded image ID: sha256:loaded-xpkg\\n"' \
  '        ;;' \
  '      name)' \
  '        printf "Loaded image: loaded-xpkg:contract\\n"' \
  '        ;;' \
  '      invalid)' \
  '        printf "Docker load completed without an image reference\\n"' \
  '        ;;' \
  '      *)' \
  '        printf "unexpected load mode\\n" >&2' \
  '        exit 1' \
  '        ;;' \
  '    esac' \
  '    ;;' \
  '  tag)' \
  '    [[ "${2:-}" == "$EXPECTED_LOADED_IMAGE" ]]' \
  '    [[ "${3:-}" == "$EXPECTED_PUSH_REF" ]]' \
  '    ;;' \
  '  push)' \
  '    [[ "${2:-}" == "$EXPECTED_PUSH_REF" ]]' \
  '    ;;' \
  '  ps)' \
  '    [[ "${2:-}" == "--format" ]]' \
  '    ;;' \
  '  run)' \
  '    [[ "$*" == *"--name kind-registry"* && "$*" == *"registry:3"* ]]' \
  '    ;;' \
  '  network)' \
  '    [[ "${2:-}" == "connect" && "${3:-}" == "kind" ]]' \
  '    ;;' \
  '  inspect)' \
  '    [[ "${2:-}" == "--format" ]]' \
  '    [[ "$*" == *"$REGISTRY_CONTAINER"* ]]' \
  '    printf "%s\\n" "$FAKE_REGISTRY_IP"' \
  '    ;;' \
  '  *)' \
  '    printf "unexpected docker command\\n" >&2' \
  '    exit 1' \
  '    ;;' \
  'esac' \
  > "$FAKE_BIN/docker"
chmod +x "$FAKE_BIN/docker"

run_build() {
  local output_file="$1"
  local load_mode="$2"
  local loaded_image="$3"

  (
    cd "$ROOT_DIR"
    TAG=contract-tag \
    REGISTRY=local \
    IMAGE_NAME=provider-harness \
    MODULE_PATH=example/provider-harness \
    HOST_PLATFORM=linux_amd64 \
    LOCAL_STATE_DIR="$TEST_ROOT/local-state" \
    XPKG_OUTPUT_DIR="$TEST_ROOT/xpkg" \
    REGISTRY_CONTAINER=kind-registry \
    KIND_NETWORK=kind \
    EXPECTED_PUSH_REF="$EXPECTED_PUSH_REF" \
    EXPECTED_LOADED_IMAGE="$loaded_image" \
    FAKE_REGISTRY_IP=172.18.0.3 \
    DOCKER_LOAD_MODE="$load_mode" \
    FAKE_BIN="$FAKE_BIN" \
    FAKE_LOG="$FAKE_LOG" \
    PATH="$FAKE_BIN:$PATH" \
    bash hack/build-xpkg.sh > "$output_file" 2>&1
  )
}

if ! run_build "$FIRST_OUTPUT" id sha256:loaded-xpkg; then
  printf 'first build failed unexpectedly\n%s\n' "$(< "$FIRST_OUTPUT")" >&2
  exit 1
fi

LOG_CONTENT="$(< "$FAKE_LOG")"
assert_log_contains() {
  local expected="$1"
  if [[ "$LOG_CONTENT" != *"$expected"* ]]; then
    printf 'missing command: %s\n%s\n' "$expected" "$LOG_CONTENT" >&2
    exit 1
  fi
}

assert_log_contains "curl -fsSLo $TEST_ROOT/local-state/bin/crossplane-cli-v2.3.4 https://cli.crossplane.io/stable/v2.3.4/bin/linux_amd64/crossplane"
assert_log_contains "docker buildx build --load --platform linux/amd64"
assert_log_contains "crossplane xpkg build --embed-runtime-image=local/provider-harness:contract-tag --package-root=$ROOT_DIR/package --examples-root=$ROOT_DIR/examples --package-file=$TEST_ROOT/xpkg/provider-harness-contract-tag.xpkg"
assert_log_contains "docker load --input $TEST_ROOT/xpkg/provider-harness-contract-tag.xpkg"
assert_log_contains "docker tag sha256:loaded-xpkg 127.0.0.1:5001/provider-harness:local"
assert_log_contains "docker push 127.0.0.1:5001/provider-harness:local"

[[ -s "$TEST_ROOT/xpkg/provider-harness-contract-tag.xpkg" ]]
[[ -x "$TEST_ROOT/local-state/bin/crossplane-cli-v2.3.4" ]]
[[ "$(< "$FIRST_OUTPUT")" == *"XPKG_FILE=$TEST_ROOT/xpkg/provider-harness-contract-tag.xpkg"* ]]
[[ "$(< "$FIRST_OUTPUT")" == *"PUSH_REF=127.0.0.1:5001/provider-harness:local"* ]]
[[ "$(< "$FIRST_OUTPUT")" == *"PACKAGE_REF=172.18.0.3:5000/provider-harness:local"* ]]
[[ "$(< "$TEST_ROOT/local-state/packageref")" == "172.18.0.3:5000/provider-harness:local" ]]
[[ "$(< "$TEST_ROOT/local-state/registry-ip")" == "172.18.0.3" ]]

if ! run_build "$SECOND_OUTPUT" name loaded-xpkg:contract; then
  printf 'second build failed unexpectedly\n%s\n' "$(< "$SECOND_OUTPUT")" >&2
  exit 1
fi

LOG_CONTENT="$(< "$FAKE_LOG")"
assert_log_contains "docker tag loaded-xpkg:contract 127.0.0.1:5001/provider-harness:local"

CURL_COUNT=0
while IFS= read -r line; do
  if [[ "$line" == curl\ * ]]; then
    ((CURL_COUNT += 1))
  fi
done < "$FAKE_LOG"
[[ "$CURL_COUNT" -eq 1 ]]

if run_build "$INVALID_OUTPUT" invalid unused-image; then
  printf 'invalid Docker load output was accepted\n' >&2
  exit 1
fi
INVALID_CONTENT="$(< "$INVALID_OUTPUT")"
[[ "$INVALID_CONTENT" == *"docker load did not report an image identifier"* ]]

printf 'build-xpkg contract: PASS\n'
