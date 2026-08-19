#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=local-xpkg-common.sh
source "$ROOT_DIR/hack/local-xpkg-common.sh"

[[ -x "$CROSSPLANE_CLI" ]] || fail "Crossplane CLI is not executable: $CROSSPLANE_CLI (run make build-xpkg to download it)"

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
