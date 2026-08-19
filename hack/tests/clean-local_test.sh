#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

FAKE_BIN="$TEST_ROOT/bin"
LOCAL_STATE_DIR="$TEST_ROOT/local-state"
XPKG_OUTPUT_DIR="$TEST_ROOT/xpkg"
FAKE_LOG="$TEST_ROOT/commands.log"
PACKAGE_REF_SAVED="172.18.0.3:5000/provider-harness:local"
PUSH_REF="127.0.0.1:5001/provider-harness:local"
GLOBAL_HELM_STATE="$TEST_ROOT/global-helm/marker"
mkdir -p "$FAKE_BIN" "$LOCAL_STATE_DIR" "$XPKG_OUTPUT_DIR" "$(dirname "$GLOBAL_HELM_STATE")"
: > "$FAKE_LOG"
: > "$GLOBAL_HELM_STATE"
: > "$XPKG_OUTPUT_DIR/provider-harness-contract-tag.xpkg"
: > "$LOCAL_STATE_DIR/provider.yaml"
printf 'provider-harness-local-xpkg\n' > "$LOCAL_STATE_DIR/.provider-harness-local-xpkg"
printf '%s\n' "$PACKAGE_REF_SAVED" > "$LOCAL_STATE_DIR/packageref"
printf '172.18.0.3\n' > "$LOCAL_STATE_DIR/registry-ip"

printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'printf "kubectl %s\\n" "$*" >> "$FAKE_LOG"' \
  'case "${1:-}" in' \
  '  delete)' \
  '    [[ "$*" == *"provider/provider-harness"* && "$*" == *"--ignore-not-found"* && "$*" == *"--wait=true"* ]]' \
  '    ;;' \
  '  get)' \
  '    request="$*"' \
  '    case "$request" in' \
  '      *"provider/provider-harness"*) [[ "${CROSSPLANE_PRESENT:-yes}" == "yes" ]] ;;' \
  '      *) printf "unexpected kubectl get: %s\\n" "$request" >&2; exit 1 ;;' \
  '    esac' \
  '    ;;' \
  '  *) printf "unexpected kubectl command: %s\\n" "$*" >&2; exit 1 ;;' \
  'esac' \
  > "$FAKE_BIN/kubectl"
chmod +x "$FAKE_BIN/kubectl"

printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'printf "kind %s\\n" "$*" >> "$FAKE_LOG"' \
  '[[ "${1:-}" == "get" && "${2:-}" == "nodes" && "$*" == *"--name provider-harness-dev"* ]]' \
  'if [[ "${KIND_PRESENT:-yes}" == "yes" ]]; then printf "provider-harness-dev-control-plane\\n"; fi' \
  > "$FAKE_BIN/kind"
chmod +x "$FAKE_BIN/kind"

printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'printf "docker %s\\n" "$*" >> "$FAKE_LOG"' \
  'case "${1:-}" in' \
  '  exec) [[ "$*" == *"ctr -n k8s.io images rm 172.18.0.3:5000/provider-harness:local"* ]] ;;' \
  '  image)' \
  '    [[ "${2:-}" == "rm" ]]' \
  '    case "${3:-}" in' \
  '      172.18.0.3:5000/provider-harness:local|127.0.0.1:5001/provider-harness:local) ;;' \
  '      *) printf "unexpected docker image rm: %s\\n" "${3:-}" >&2; exit 1 ;;' \
  '    esac' \
  '    ;;' \
  '  ps)' \
  '    [[ "${2:-}" == "--format" ]]' \
  '    if [[ "${REGISTRY_PRESENT:-yes}" == "yes" ]]; then printf "kind-registry\\n"; fi' \
  '    ;;' \
  '  rm)' \
  '    [[ "${2:-}" == "-f" && "${3:-}" == "kind-registry" ]]' \
  '    ;;' \
  '  *) printf "unexpected docker command: %s\\n" "$*" >&2; exit 1 ;;' \
  'esac' \
  > "$FAKE_BIN/docker"
chmod +x "$FAKE_BIN/docker"

run_clean() {
  (
    cd "$ROOT_DIR"
    env \
      KIND_CLUSTER_NAME=provider-harness-dev \
      REGISTRY_CONTAINER=kind-registry \
      PUSH_REF="$PUSH_REF" \
      XPKG_OUTPUT_DIR="${CLEAN_XPKG_OUTPUT_DIR:-$XPKG_OUTPUT_DIR}" \
      LOCAL_STATE_DIR="${CLEAN_STATE_DIR:-$LOCAL_STATE_DIR}" \
      HELM_CONFIG_HOME="${CLEAN_STATE_DIR:-$LOCAL_STATE_DIR}/helm/config" \
      HELM_CACHE_HOME="${CLEAN_STATE_DIR:-$LOCAL_STATE_DIR}/helm/cache" \
      HELM_DATA_HOME="${CLEAN_STATE_DIR:-$LOCAL_STATE_DIR}/helm/data" \
      FAKE_LOG="$FAKE_LOG" \
      CROSSPLANE_PRESENT="${CROSSPLANE_PRESENT:-yes}" \
      REGISTRY_PRESENT="${REGISTRY_PRESENT:-yes}" \
      PATH="$FAKE_BIN:$PATH" \
      bash hack/clean-local.sh
  )
}

assert_log_contains() {
  local expected="$1"
  local content
  content="$(< "$FAKE_LOG")"
  [[ "$content" == *"$expected"* ]] || {
    printf 'missing command: %s\n%s\n' "$expected" "$content" >&2
    return 1
  }
}

assert_log_before() {
  local first="$1"
  local second="$2"
  local line index=0 first_index=-1 second_index=-1
  while IFS= read -r line; do
    ((index += 1))
    [[ "$first_index" -eq -1 && "$line" == *"$first"* ]] && first_index="$index"
    [[ "$second_index" -eq -1 && "$line" == *"$second"* ]] && second_index="$index"
  done < "$FAKE_LOG"
  [[ "$first_index" -ge 0 && "$second_index" -ge 0 && "$first_index" -lt "$second_index" ]] || {
    printf 'expected %s before %s\n%s\n' "$first" "$second" "$(< "$FAKE_LOG")" >&2
    return 1
  }
}

run_clean

[[ ! -e "$XPKG_OUTPUT_DIR/provider-harness-contract-tag.xpkg" ]]
[[ ! -e "$LOCAL_STATE_DIR" ]]
[[ -e "$GLOBAL_HELM_STATE" ]]
assert_log_contains 'kubectl delete provider/provider-harness --ignore-not-found --wait=true'
assert_log_contains 'docker exec provider-harness-dev-control-plane ctr -n k8s.io images rm 172.18.0.3:5000/provider-harness:local'
assert_log_contains 'docker image rm 172.18.0.3:5000/provider-harness:local'
assert_log_contains 'docker image rm 127.0.0.1:5001/provider-harness:local'
assert_log_contains 'docker rm -f kind-registry'
assert_log_before 'kubectl delete provider/provider-harness' 'docker exec'
assert_log_before 'docker exec' 'docker image rm 172.18.0.3:5000/provider-harness:local'
assert_log_before 'docker image rm 172.18.0.3:5000/provider-harness:local' 'docker rm -f kind-registry'

if [[ "$(< "$FAKE_LOG")" == *'helm uninstall'* || "$(< "$FAKE_LOG")" == *'delete namespace'* || "$(< "$FAKE_LOG")" == *'kind delete cluster'* ]]; then
  printf 'cleanup touched forbidden global or cluster state\n%s\n' "$(< "$FAKE_LOG")" >&2
  exit 1
fi

run_clean

[[ ! -e "$XPKG_OUTPUT_DIR/provider-harness-contract-tag.xpkg" ]]
[[ ! -e "$LOCAL_STATE_DIR" ]]
[[ -e "$GLOBAL_HELM_STATE" ]]

mkdir -p "$LOCAL_STATE_DIR" "$XPKG_OUTPUT_DIR"
printf 'provider-harness-local-xpkg\n' > "$LOCAL_STATE_DIR/.provider-harness-local-xpkg"
: > "$LOCAL_STATE_DIR/provider.yaml"
printf '%s\n' "$PACKAGE_REF_SAVED" > "$LOCAL_STATE_DIR/packageref"
printf '172.18.0.3\n' > "$LOCAL_STATE_DIR/registry-ip"
: > "$XPKG_OUTPUT_DIR/provider-harness-contract-tag.xpkg"
rm -f "$FAKE_LOG"
: > "$FAKE_LOG"
CROSSPLANE_PRESENT=no run_clean
[[ ! -e "$XPKG_OUTPUT_DIR/provider-harness-contract-tag.xpkg" ]]
[[ ! -e "$LOCAL_STATE_DIR" ]]
[[ "$(< "$FAKE_LOG")" != *'kubectl delete provider/provider-harness'* ]]
[[ "$(< "$FAKE_LOG")" == *'docker rm -f kind-registry'* ]]

UNMARKED_STATE="$TEST_ROOT/unmarked-state"
UNMARKED_XPKG="$TEST_ROOT/unmarked-xpkg"
mkdir -p "$UNMARKED_STATE" "$UNMARKED_XPKG"
: > "$UNMARKED_STATE/unrelated"
: > "$UNMARKED_XPKG/provider-harness-contract-tag.xpkg"
if CLEAN_STATE_DIR="$UNMARKED_STATE" CLEAN_XPKG_OUTPUT_DIR="$UNMARKED_XPKG" run_clean; then
  printf 'cleanup accepted an unmarked state directory\n' >&2
  exit 1
fi
[[ -e "$UNMARKED_STATE/unrelated" ]]
[[ -e "$UNMARKED_XPKG/provider-harness-contract-tag.xpkg" ]]

printf 'clean-local contract: PASS\n'
