# provider-harness

A Crossplane Provider for Harness NextGen. Built and published as a single
self-contained OCI image that the org Harness CI pipeline builds (multi-arch),
scans, and pushes to the Harness container registry / ECR.

## Image build

The provider is a single self-contained image: the Crossplane v2 package image
*is* the runtime. `Dockerfile.org` builds it (Go binary + flattened
`package.yaml` + entrypoint, distroless/static base).

The image is built by the Harness CI pipeline with Kaniko (no Makefile or Docker
daemon needed):

```bash
VERSION="$(cat VERSION)"
# per arch, then combined into a multi-arch manifest:
/kaniko/executor \
  --build-arg BUILDARCH=${ARCH} \
  --build-arg GOLANG_IMAGE=<private-golang-mirror> \
  --build-arg RUNTIME_IMAGE=<private-distroless-mirror> \
  --build-arg GOPROXY=<internal-goproxy-or-default> \
  --build-arg GOSUMDB=<internal-gosumdb-or-default> \
  --build-arg GONOSUMDB= \
  --build-arg MODULE_PATH=github.com/jeremywyx/provider-harness \
  --build-arg VERSION="${VERSION}" \
  --context . \
  --dockerfile Dockerfile.org \
  --destination=<registry>/<project>/provider-harness:${VERSION}-${ARCH} \
  --tarPath=provider-harness-${ARCH}.tar \
  --no-push
```

## Version

The image version is defined in the committed `VERSION` file (single source of
truth). It is passed as the `VERSION` build arg (baked into the binary via
`internal/version.Version`) and used as the image tag. Bump `VERSION` before a
release; do not derive it from git tags (the repo is tagged for other resources).

## Regenerating `package.yaml`

`package.yaml` is the committed flattened package manifest (`package/crossplane.yaml`
+ `package/crds/*`). When the CRDs change, regenerate it and commit:

```bash
make xpkg-yaml
git diff --exit-code package.yaml   # ensure in sync
```

## Deploying to a control plane

`deploy/provider.yaml` is the Provider manifest (fill in the registry host /
project / pull-secret placeholders). Apply it to an org control plane; Crossplane
pulls the one image and uses it as both package and runtime.
