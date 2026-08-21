#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log() { printf '[xpkg] %s\n' "$*"; }
fail() { printf '[xpkg] ERROR: %s\n' "$*" >&2; exit 1; }

PACKAGE_ROOT="${PACKAGE_ROOT:-$ROOT_DIR/package}"
EXAMPLES_ROOT="${EXAMPLES_ROOT:-$ROOT_DIR/examples}"
CROSSPLANE_CLI_VERSION="${CROSSPLANE_CLI_VERSION:-v2.3.4}"
CROSSPLANE_CLI="${CROSSPLANE_CLI:-$ROOT_DIR/.cache/bin/crossplane-cli-$CROSSPLANE_CLI_VERSION}"

download_cli() {
  local host_platform
  case "$(uname -s):$(uname -m)" in
    Darwin:x86_64|Darwin:amd64) host_platform="darwin_amd64" ;;
    Darwin:arm64|Darwin:aarch64) host_platform="darwin_arm64" ;;
    Linux:x86_64|Linux:amd64) host_platform="linux_amd64" ;;
    Linux:arm64|Linux:aarch64) host_platform="linux_arm64" ;;
    *) fail "unsupported host platform: $(uname -s)/$(uname -m)" ;;
  esac
  command -v curl >/dev/null 2>&1 || fail "curl is required to download the Crossplane CLI"
  mkdir -p "$(dirname "$CROSSPLANE_CLI")"
  curl -fsSLo "$CROSSPLANE_CLI" \
    "https://cli.crossplane.io/stable/${CROSSPLANE_CLI_VERSION}/bin/${host_platform}/crossplane"
  chmod +x "$CROSSPLANE_CLI"
}

if [[ ! -x "$CROSSPLANE_CLI" ]]; then
  download_cli
fi
[[ -x "$CROSSPLANE_CLI" ]] || fail "Crossplane CLI is not executable: $CROSSPLANE_CLI"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/layers"

"$CROSSPLANE_CLI" xpkg build \
  --package-root="$PACKAGE_ROOT" \
  --examples-root="$EXAMPLES_ROOT" \
  -o "$TMP/pkg.xpkg"

tar -xzf "$TMP/pkg.xpkg" -C "$TMP/layers"

found=""
for layer in "$TMP/layers"/*.tar.gz; do
  if tar -tzf "$layer" 2>/dev/null | grep -qx 'package.yaml'; then
    tar -xzf "$layer" -C "$TMP" package.yaml
    found=1
    break
  fi
done
[[ -n "$found" ]] || fail "package.yaml not found in built xpkg"

cp "$TMP/package.yaml" "$ROOT_DIR/package.yaml"
log "regenerated $ROOT_DIR/package.yaml"
