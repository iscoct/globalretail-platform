# Multi-stage Dockerfile.
#
# Stage 1 (build): compile a static Go binary in a full Go toolchain image.
# Stage 2 (runtime): copy the binary into distroless/static — ~5 MiB final
# image, no shell, no libc, no nothing except the binary and CA certs.

ARG GO_VERSION=1.23

# --- Stage 1: build a static binary ------------------------------------------
FROM golang:${GO_VERSION}-bookworm AS build
WORKDIR /src

# Cache the module download in a separate layer.
COPY go.mod go.sum ./
RUN go mod download

COPY . .

# CGO_ENABLED=0 -> pure Go binary -> works in distroless/static.
# -trimpath strips local file system paths from the binary (smaller + more
#  reproducible). -ldflags='-s -w' strips debug symbols (smaller).
RUN CGO_ENABLED=0 GOOS=linux \
    go build -trimpath -ldflags='-s -w' -o /out/inventory-api .

# --- Stage 2: distroless static runtime --------------------------------------
FROM gcr.io/distroless/static-debian12:nonroot AS runtime
WORKDIR /app
ENV PORT=3000

# Copy the binary from the build stage. distroless/static:nonroot already
# runs as uid 65532 — same as sample-app — so the K8s Deployment's
# securityContext can be identical across both apps.
COPY --from=build /out/inventory-api /usr/local/bin/inventory-api

USER 65532:65532
EXPOSE 3000

ENTRYPOINT ["/usr/local/bin/inventory-api"]
