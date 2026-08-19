#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=local-xpkg-common.sh
source "$ROOT_DIR/hack/local-xpkg-common.sh"

require_local_state_marker
require_command kubectl
require_command kind
require_command docker

PACKAGE_REF_SAVED="$(cat "$LOCAL_STATE_DIR/packageref" 2>/dev/null || true)"
REGISTRY_IP_SAVED="$(cat "$LOCAL_STATE_DIR/registry-ip" 2>/dev/null || true)"
if [[ -n "$REGISTRY_IP_SAVED" ]]; then
  REGISTRY_IP="$REGISTRY_IP_SAVED"
fi

if kubectl get provider/provider-harness --ignore-not-found >/dev/null 2>&1; then
  kubectl delete provider/provider-harness --ignore-not-found --wait=true
fi

NODE_REF="${PACKAGE_REF_SAVED:-}"
if [[ -z "$NODE_REF" ]]; then
  NODE_REF="$(package_ref 2>/dev/null || true)"
fi
KIND_NODES="$(kind get nodes --name "$KIND_CLUSTER_NAME" 2>/dev/null || true)"
for node in $KIND_NODES; do
  if [[ -n "$NODE_REF" ]]; then
    docker exec "$node" ctr -n k8s.io images rm "$NODE_REF" || true
  fi
done

if [[ -n "$PACKAGE_REF_SAVED" ]]; then
  docker image rm "$PACKAGE_REF_SAVED" || true
fi
docker image rm "$PUSH_REF" || true

if docker ps --format '{{.Names}}' | grep -qx "$REGISTRY_CONTAINER"; then
  docker rm -f "$REGISTRY_CONTAINER" >/dev/null 2>&1 || true
fi

rm -f "$XPKG_FILE" "$LOCAL_STATE_DIR/provider.yaml"
if [[ -e "$LOCAL_STATE_DIR" ]]; then
  rm -rf "$LOCAL_STATE_DIR"
fi
