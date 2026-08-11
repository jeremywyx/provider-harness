# Build stage: compiles the provider binary inside the image.
# All network access flows through the Go module proxy (GOPROXY/GOSUMDB).
ARG BASE_REGISTRY=gcr.io
FROM ${BASE_REGISTRY}/golang:1.25.11 AS builder

ARG GOPROXY=https://proxy.golang.org,direct
ARG GOSUMDB=sum.golang.org
ARG GONOSUMDB=""
ARG MODULE_PATH=github.com/jeremywyx/provider-harness
ARG VERSION=0.0.0

WORKDIR /src
COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod \
    go mod download

COPY . .
RUN --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 go build -trimpath \
    -ldflags="-s -w -X ${MODULE_PATH}/internal/version.Version=${VERSION}" \
    -o /out/harness-provider ./cmd/provider

# Runtime stage: minimal distroless image.
ARG BASE_REGISTRY=gcr.io
FROM ${BASE_REGISTRY}/distroless/static@sha256:d9f9472a8f4541368192d714a995eb1a99bab1f7071fc8bde261d7eda3b667d8

COPY --from=builder /out/harness-provider /usr/local/bin/harness-provider

USER 65532
ENTRYPOINT ["harness-provider"]
