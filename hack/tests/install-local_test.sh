#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

FAKE_BIN="$TEST_ROOT/bin"
mkdir -p "$FAKE_BIN"

EXPECTED_PUSH_REF="127.0.0.1:5001/provider-harness:local"
EXPECTED_PACKAGE_REF="172.18.0.3:5000/provider-harness:local"

write_fakes() {
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'printf "kind %s\\n" "$*" >> "$FAKE_LOG"' \
    'case "${1:-}" in' \
    '  get) [[ "${2:-}" == "clusters" ]]; if [[ "${KIND_CLUSTER_PRESENT:-yes}" == "yes" ]]; then printf "%s\\n" "$KIND_CLUSTER_NAME"; fi ;;' \
    '  load) [[ "${2:-}" == "docker-image" && "${3:-}" == "$EXPECTED_PACKAGE_REF" ]] ;;' \
    '  *) printf "unexpected kind command\\n" >&2; exit 1 ;;' \
    'esac' \
    > "$FAKE_BIN/kind"
  chmod +x "$FAKE_BIN/kind"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'printf "helm %s HELM_CONFIG_HOME=%s HELM_CACHE_HOME=%s HELM_DATA_HOME=%s\\n" "$*" "$HELM_CONFIG_HOME" "$HELM_CACHE_HOME" "$HELM_DATA_HOME" >> "$FAKE_LOG"' \
    '[[ "$HELM_CONFIG_HOME" == "$LOCAL_STATE_DIR"/* ]]' \
    '[[ "$HELM_CACHE_HOME" == "$LOCAL_STATE_DIR"/* ]]' \
    '[[ "$HELM_DATA_HOME" == "$LOCAL_STATE_DIR"/* ]]' \
    'case "${1:-}" in' \
    '  repo) [[ "${2:-}" == "add" ]] ;;' \
    '  upgrade) [[ "${2:-}" == "--install" && "${3:-}" == "crossplane" && "$*" == *"--version 2.3.4"* ]] ;;' \
    '  *) printf "unexpected helm command\\n" >&2; exit 1 ;;' \
    'esac' \
    > "$FAKE_BIN/helm"
  chmod +x "$FAKE_BIN/helm"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'printf "docker %s\\n" "$*" >> "$FAKE_LOG"' \
    'case "${1:-}" in' \
    '  image) [[ "${2:-}" == "inspect" ]]; if [[ "${IMAGE_PRESENT:-yes}" == "yes" ]]; then exit 0; else exit 1; fi ;;' \
    '  buildx) [[ "${2:-}" == "build" ]] ;;' \
    '  load)' \
    '    [[ "${2:-}" == "--input" && -f "$3" ]]' \
    '    printf "Loaded image ID: sha256:loaded-xpkg\\n"' \
    '    ;;' \
    '  tag)' \
  '    if [[ "${2:-}" == "$EXPECTED_LOADED_IMAGE" && "${3:-}" == "$EXPECTED_PUSH_REF" ]]; then :;' \
  '    elif [[ "${2:-}" == "$EXPECTED_PUSH_REF" && "${3:-}" == "$EXPECTED_PACKAGE_REF" ]]; then :;' \
  '    else exit 1; fi' \
  '    ;;' \
    '  push) [[ "${2:-}" == "$EXPECTED_PUSH_REF" ]] ;;' \
    '  ps) [[ "${2:-}" == "--format" ]] ;;' \
    '  run) [[ "$*" == *"--name kind-registry"* && "$*" == *"registry:3"* ]]' \
    '       printf "created\\n"; ;;' \
    '  network) [[ "${2:-}" == "connect" && "${3:-}" == "kind" ]] ;;' \
    '  inspect) [[ "${2:-}" == "--format" ]] && printf "%s\\n" "$FAKE_REGISTRY_IP" ;;' \
    '  *) printf "unexpected docker command\\n" >&2; exit 1 ;;' \
    'esac' \
    > "$FAKE_BIN/docker"
  chmod +x "$FAKE_BIN/docker"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'printf "crossplane %s\\n" "$*" >> "$FAKE_LOG"' \
    '[[ "${1:-}" == "xpkg" && "${2:-}" == "build" ]]' \
    'package_file=' \
    'for arg in "$@"; do [[ "$arg" == --package-file=* ]] && package_file="${arg#*=}"; done' \
    '[[ -n "$package_file" ]]' \
    'mkdir -p "$(dirname "$package_file")"' \
    'printf "xpkg\\n" > "$package_file"' \
    > "$FAKE_BIN/crossplane"
  chmod +x "$FAKE_BIN/crossplane"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'printf "kubectl %s\\n" "$*" >> "$FAKE_LOG"' \
    'case "${1:-}" in' \
    '  apply)' \
    '    manifest="$(< "${3:-}")"' \
    '    [[ "${2:-}" == "-f" && "$manifest" == *"name: provider-harness"* ]]' \
    '    [[ "$manifest" == *"package: $EXPECTED_PACKAGE_REF"* ]]' \
    '    if [[ "$manifest" == *"packagePullPolicy: Never"* ]]; then' \
    '      printf "packagePullPolicy Never must not be set\\n" >&2' \
    '      exit 1' \
    '    fi' \
    '    ;;' \
    '  patch|rollout|wait) exit 0 ;;' \
  '  get)' \
  '    request="$*"' \
  '    case "$request" in' \
  '      *"go-template"*"provider-harness"*) printf "provider-deployment" ;;' \
  '      *"deployment"*"containers[0].image"*) printf "%s" "$EXPECTED_PACKAGE_REF" ;;' \
  '      *"provider/provider-harness"*) printf "provider-harness\\n" ;;' \
  '      *) printf "unexpected kubectl get: %s\\n" "$request" >&2; exit 1 ;;' \
  '    esac' \
  '    ;;' \
    '  *) printf "unexpected kubectl command\\n" >&2; exit 1 ;;' \
    'esac' \
    > "$FAKE_BIN/kubectl"
  chmod +x "$FAKE_BIN/kubectl"
}

assert_log_contains() {
  local log_file="$1"
  local expected="$2"
  local content
  content="$(< "$log_file")"
  [[ "$content" == *"$expected"* ]] || {
    printf 'missing command: %s\n%s\n' "$expected" "$content" >&2
    return 1
  }
}

assert_log_before() {
  local log_file="$1"
  local first="$2"
  local second="$3"
  local line index=0 first_index=-1 second_index=-1
  while IFS= read -r line; do
    ((index += 1))
    [[ "$first_index" -eq -1 && "$line" == *"$first"* ]] && first_index="$index"
    [[ "$second_index" -eq -1 && "$line" == *"$second"* ]] && second_index="$index"
  done < "$log_file"
  [[ "$first_index" -ge 0 && "$second_index" -ge 0 && "$first_index" -lt "$second_index" ]] || {
    printf 'expected %s before %s in %s\n%s\n' "$first" "$second" "$log_file" "$(< "$log_file")" >&2
    return 1
  }
}

assert_log_starts_with() {
  local log_file="$1"
  local expected="$2"
  local first_line
  IFS= read -r first_line < "$log_file"
  [[ "$first_line" == "$expected" ]] || {
    printf 'expected first command %s, got %s\n' "$expected" "$first_line" >&2
    return 1
  }
}

run_install() {
  local case_root="$1"
  local image_present="${2:-yes}"
  local cluster_present="${3:-yes}"
  local output_file="$case_root/output.log"
  (
    cd "$ROOT_DIR"
    env \
      KIND_CLUSTER_NAME=provider-harness-dev \
      REGISTRY_CONTAINER=kind-registry \
      KIND_NETWORK=kind \
      FAKE_REGISTRY_IP=172.18.0.3 \
      EXPECTED_PUSH_REF="$EXPECTED_PUSH_REF" \
      EXPECTED_PACKAGE_REF="$EXPECTED_PACKAGE_REF" \
      EXPECTED_LOADED_IMAGE="sha256:loaded-xpkg" \
      TAG=contract-tag \
      CROSSPLANE_VERSION=2.3.4 \
      CROSSPLANE_CLI_VERSION=v2.3.4 \
      XPKG_OUTPUT_DIR="$case_root/xpkg" \
      LOCAL_STATE_DIR="$case_root/local-state" \
      XPKG_FILE="$case_root/xpkg/provider-harness-contract-tag.xpkg" \
      HELM_CONFIG_HOME="$case_root/local-state/helm/config" \
      HELM_CACHE_HOME="$case_root/local-state/helm/cache" \
      HELM_DATA_HOME="$case_root/local-state/helm/data" \
      FAKE_LOG="$case_root/commands.log" \
      IMAGE_PRESENT="$image_present" \
      KIND_CLUSTER_PRESENT="$cluster_present" \
      PATH="$FAKE_BIN:$PATH" \
      bash hack/install-local.sh > "$output_file" 2>&1
  )
}

setup_case() {
  local case_root="$1"
  local xpkg_present="$2"
  local image_present="$3"
  mkdir -p "$case_root/xpkg" "$case_root/local-state/bin"
  printf 'provider-harness-local-xpkg\n' > "$case_root/local-state/.provider-harness-local-xpkg"
  : > "$case_root/commands.log"
  cp "$FAKE_BIN/crossplane" "$case_root/local-state/bin/crossplane-cli-v2.3.4"
  chmod +x "$case_root/local-state/bin/crossplane-cli-v2.3.4"
  if [[ "$xpkg_present" == yes ]]; then
    printf 'xpkg\n' > "$case_root/xpkg/provider-harness-contract-tag.xpkg"
  fi
  if [[ "$image_present" == yes ]]; then
    : > "$case_root/image-present"
  fi
}

write_fakes

FALLBACK_ROOT="$TEST_ROOT/fallback"
setup_case "$FALLBACK_ROOT" no no
run_install "$FALLBACK_ROOT" no
FALLBACK_LOG="$FALLBACK_ROOT/commands.log"
assert_log_starts_with "$FALLBACK_LOG" 'kind get clusters'
assert_log_contains "$FALLBACK_LOG" 'docker buildx build --load --platform linux/amd64'
assert_log_contains "$FALLBACK_LOG" 'crossplane xpkg build --embed-runtime-image=local/provider-harness:contract-tag'
assert_log_contains "$FALLBACK_LOG" 'docker load --input'
assert_log_contains "$FALLBACK_LOG" 'docker push 127.0.0.1:5001/provider-harness:local'
assert_log_before "$FALLBACK_LOG" 'kind get clusters' 'helm repo add'
assert_log_before "$FALLBACK_LOG" 'docker push' 'kubectl apply -f'
assert_log_before "$FALLBACK_LOG" 'kind load docker-image' 'kubectl apply -f'
[[ -s "$FALLBACK_ROOT/xpkg/provider-harness-contract-tag.xpkg" ]]
[[ "$(< "$FALLBACK_ROOT/local-state/packageref")" == "172.18.0.3:5000/provider-harness:local" ]]

VALID_ROOT="$TEST_ROOT/valid"
setup_case "$VALID_ROOT" yes yes
run_install "$VALID_ROOT" yes
run_install "$VALID_ROOT" yes
VALID_LOG="$VALID_ROOT/commands.log"
assert_log_starts_with "$VALID_LOG" 'kind get clusters'
assert_log_contains "$VALID_LOG" 'helm upgrade --install crossplane crossplane-stable/crossplane --version 2.3.4'
assert_log_contains "$VALID_LOG" 'kind load docker-image 172.18.0.3:5000/provider-harness:local'
assert_log_contains "$VALID_LOG" 'kubectl apply -f'
assert_log_before "$VALID_LOG" 'kind get clusters' 'helm repo add'
assert_log_before "$VALID_LOG" 'helm upgrade' 'kind load docker-image'
assert_log_before "$VALID_LOG" 'kind load docker-image' 'kubectl apply -f'
DOCKER_PUSH_COUNT=0
while IFS= read -r line; do
  [[ "$line" == docker\ push* ]] && ((DOCKER_PUSH_COUNT += 1))
done < "$VALID_LOG"
[[ "$DOCKER_PUSH_COUNT" -eq 0 ]]
if [[ "$VALID_LOG" == *'docker buildx build'* ]]; then
  printf 'valid install unexpectedly rebuilt the image\n%s\n' "$(< "$VALID_LOG")" >&2
  exit 1
fi

MISSING_IMAGE_ROOT="$TEST_ROOT/existing-xpkg-missing-image"
setup_case "$MISSING_IMAGE_ROOT" yes no
run_install "$MISSING_IMAGE_ROOT" no
MISSING_IMAGE_LOG="$MISSING_IMAGE_ROOT/commands.log"
assert_log_contains "$MISSING_IMAGE_LOG" 'docker load --input'
assert_log_contains "$MISSING_IMAGE_LOG" 'docker push 127.0.0.1:5001/provider-harness:local'

MISSING_CLUSTER_ROOT="$TEST_ROOT/missing-cluster"
setup_case "$MISSING_CLUSTER_ROOT" no no
if run_install "$MISSING_CLUSTER_ROOT" no no; then
  printf 'missing kind cluster was accepted\n' >&2
  exit 1
fi
MISSING_CLUSTER_LOG="$MISSING_CLUSTER_ROOT/commands.log"
assert_log_starts_with "$MISSING_CLUSTER_LOG" 'kind get clusters'
MISSING_CLUSTER_CONTENT="$(< "$MISSING_CLUSTER_LOG")"
if [[ "$MISSING_CLUSTER_CONTENT" == *'docker buildx build'* || "$MISSING_CLUSTER_CONTENT" == *'docker push'* || "$MISSING_CLUSTER_CONTENT" == *'helm '* || "$MISSING_CLUSTER_CONTENT" == *'docker run'* ]]; then
  printf 'cluster validation occurred after side effects\n%s\n' "$MISSING_CLUSTER_CONTENT" >&2
  exit 1
fi

printf 'install-local contract: PASS\n'
