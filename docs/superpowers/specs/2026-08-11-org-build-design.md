# Org Build Adaptation Design

**Date:** 2026-08-11
**Branch:** feat/org-build
**Status:** Approved (design)

## Context

The repo moves to the user's org, which has three constraints:

1. **No GitHub Actions** — a self-built CI pipeline builds the package. The repo must
   expose simple build entrypoints (scripts / make targets) the pipeline can invoke.
2. **Restricted network** — only access to private registries. Container images, Go
   modules, and tool downloads must all be routed through private registries via
   env-var / build-arg parameters.
3. **Build binary within a Docker image** — a multi-stage Dockerfile compiles the Go
   binary inside a builder stage instead of building on the host and copying it in.

## Approach

Standalone multi-stage Dockerfile at repo root + a thin wrapper script. The org
pipeline runs a single `docker buildx build`. No GitHub Actions, no `build/` git
submodule required for the image build, all network touchpoints parameterized.

## Components

### 1. `Dockerfile` (repo root, multi-stage)

**Stage 1 — builder:**

- Base: `${BASE_REGISTRY}/golang:1.25.11` (default `gcr.io`)
- Build args: `GOPROXY` (default `https://proxy.golang.org,direct`), `GOSUMDB`
  (default `sum.golang.org`), `GONOSUMDB` (default empty), `MODULE_PATH`
  (default `github.com/jeremywyx/provider-harness`), `VERSION` (default `0.0.0`)
- `WORKDIR /src`; copy `go.mod go.sum`; `go mod download` with a BuildKit cache
  mount on `/go/pkg/mod`
- Copy rest of source; `CGO_ENABLED=0 go build -trimpath
  -ldflags="-s -w -X ${MODULE_PATH}/internal/version.Version=${VERSION}"
  -o /out/harness-provider ./cmd/provider`

**Stage 2 — runtime:**

- Base: `${BASE_REGISTRY}/distroless/static` pinned to the current digest
  `sha256:d9f9472a8f4541368192d714a995eb1a99bab1f7071fc8bde261d7eda3b667d8`
- `COPY --from=builder /out/harness-provider /usr/local/bin/harness-provider`
- `USER 65532`, `ENTRYPOINT ["harness-provider"]`

Rationale:

- Builder stage needs no network beyond the Go module proxy; `go mod download`
  flows through `GOPROXY` / `GOSUMDB` / `GONOSUMDB` args so private proxies and
  private module paths work in restricted networks.
- BuildKit cache mount gives incremental `go mod download` caching between builds.
- Version is baked in via `-X` using the parameterized module path (org path may
  differ from `github.com/jeremywyx/provider-harness`).
- Runtime image content is unchanged from the current Dockerfile; only the binary
  name and entrypoint change to `harness-provider`.
- `TARGETOS`/`TARGETARCH` come automatically from `docker build --platform`.

### 2. `hack/build-image.sh` (pipeline entrypoint)

Standalone bash script, no submodule. Reads env vars with safe defaults, invokes
`docker buildx build`, prints the resulting image ref.

Env vars (all optional, defaults shown):

| Var | Default |
|---|---|
| `REGISTRY` | `local` (e.g. `harbor.corp.com/harness`) |
| `IMAGE_NAME` | `provider-harness` |
| `TAG` | `git describe --always --dirty` or `dev` |
| `PLATFORMS` | `linux/amd64,linux/arm64` |
| `BASE_REGISTRY` | `gcr.io` |
| `GOPROXY` | `https://proxy.golang.org,direct` |
| `GOSUMDB` | `sum.golang.org` |
| `GONOSUMDB` | `` |
| `MODULE_PATH` | `github.com/jeremywyx/provider-harness` |
| `VERSION` | `$TAG` |
| `BUILD_ARGS` | `--load` |

Default `BUILD_ARGS=--load` mirrors current CI behavior. The org pipeline can set
`BUILD_ARGS="--push"` and `REGISTRY=<private registry>` to push directly.

### 3. Makefile and cleanup

- Add `build-image` target to root `Makefile` that shells out to
  `hack/build-image.sh`. It works even when the `build/` submodule is not
  initialized because it does not include the makelib files.
- Remove GitHub Actions workflows (`.github/workflows/*`) — no GH Actions in org.
- Leave `build/` submodule and existing make targets intact for local dev; the
  image build no longer depends on them.

## Error handling

- Script fails fast (`set -euo pipefail`); docker build failures propagate.
- Non-zero exit from any build arg passthrough surfaces as a script failure.

## Testing

- `shellcheck hack/build-image.sh` (if available).
- Smoke build: `docker buildx build --load -t provider-harness:test .` locally with
  defaults to confirm binary builds and entrypoint runs (`docker run --rm
  provider-harness:test --help`).
- Confirm `make build-image` works with no submodule initialized (rename `build/`
  temporarily).

## Out of scope

- Crossplane xpkg packaging (image only).
- Pushing to the private registry (left to the org pipeline via `BUILD_ARGS`).
- Changing the Go module path / rewriting imports.
