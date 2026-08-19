#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=local-xpkg-common.sh
source "$ROOT_DIR/hack/local-xpkg-common.sh"

require_command kind
require_command kubectl
require_command helm
require_command docker

CLUSTERS="$(kind get clusters)"
[[ "$CLUSTERS" == *"$KIND_CLUSTER_NAME"* ]] || fail "kind cluster not found: $KIND_CLUSTER_NAME"

ensure_local_state_dir
mkdir -p "$XPKG_OUTPUT_DIR" "$(dirname "$XPKG_FILE")"
ensure_registry

if [[ ! -f "$XPKG_FILE" ]] || ! docker image inspect "$PUSH_REF" >/dev/null 2>&1; then
  "$ROOT_DIR/hack/build-xpkg.sh"
fi

[[ -f "$XPKG_FILE" ]] || fail "xpkg file does not exist: $XPKG_FILE"
require_command "$CROSSPLANE_CLI"

if ! docker image inspect "$PUSH_REF" >/dev/null 2>&1; then
  LOADED_IMAGE="$(loaded_image_id "$XPKG_FILE")"
  docker tag "$LOADED_IMAGE" "$PUSH_REF"
  docker push "$PUSH_REF"
fi

PACKAGE_REF="$(package_ref)"
validate_package_ref "$PACKAGE_REF"
printf '%s\n' "$PACKAGE_REF" > "$LOCAL_STATE_DIR/packageref"
printf '%s\n' "$REGISTRY_IP" > "$LOCAL_STATE_DIR/registry-ip"

export HELM_CONFIG_HOME HELM_CACHE_HOME HELM_DATA_HOME
helm repo add crossplane-stable https://charts.crossplane.io/stable --force-update
helm upgrade --install crossplane crossplane-stable/crossplane \
  --version "$CROSSPLANE_VERSION" \
  --namespace "$CROSSPLANE_NAMESPACE" \
  --create-namespace \
  --wait \
  --timeout 10m

kubectl rollout status "deployment/crossplane" \
  --namespace "$CROSSPLANE_NAMESPACE" \
  --timeout=10m

docker tag "$PUSH_REF" "$PACKAGE_REF"
kind load docker-image "$PACKAGE_REF" --name "$KIND_CLUSTER_NAME"

PROVIDER_MANIFEST="$LOCAL_STATE_DIR/provider.yaml"
cat > "$PROVIDER_MANIFEST" <<EOF
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: provider-harness
spec:
  package: $PACKAGE_REF
EOF

kubectl apply -f "$PROVIDER_MANIFEST"
kubectl wait \
  --for=condition=Installed=True \
  provider/provider-harness \
  --timeout=10m
kubectl wait \
  --for=condition=Healthy=True \
  provider/provider-harness \
  --timeout=10m

PROVIDER_DEPLOYMENT="$(kubectl get deployment \
  --namespace "$CROSSPLANE_NAMESPACE" \
  --output='go-template={{range .items}}{{if eq (index .spec.template.metadata.labels "pkg.crossplane.io/provider") "'"$PACKAGE_NAME"'"}}{{.metadata.name}}{{end}}{{end}}')"
[[ -n "$PROVIDER_DEPLOYMENT" ]] || fail "provider deployment not found"

kubectl rollout status "deployment/$PROVIDER_DEPLOYMENT" \
  --namespace "$CROSSPLANE_NAMESPACE" \
  --timeout=10m
PROVIDER_IMAGE="$(kubectl get "deployment/$PROVIDER_DEPLOYMENT" \
  --namespace "$CROSSPLANE_NAMESPACE" \
  --output='jsonpath={.spec.template.spec.containers[0].image}')"
[[ "$PROVIDER_IMAGE" == "$PACKAGE_REF" ]] || \
  fail "provider deployment image is $PROVIDER_IMAGE, expected $PACKAGE_REF"

kubectl get provider/provider-harness
printf 'Provider deployment: %s\n' "$PROVIDER_DEPLOYMENT"
printf 'Package reference: %s\n' "$PACKAGE_REF"
printf 'Registry: %s (%s container)\n' "$REGISTRY_CONTAINER" "$REGISTRY_IP"
printf 'Cleanup: make local-clean\n'
