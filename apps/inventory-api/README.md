# inventory-api

A second sample app on the GlobalRetail platform. Written in Go to prove the platform is language-agnostic — the same CI/CD, GitOps, observability, and policy pipelines that handle Node's `sample-app` also handle this one.

## Routes

| Method | Path | Response |
|--------|------|----------|
| GET    | `/health` | `{"status":"ok","uptimeSeconds":N}` |
| GET    | `/version` | `{"name":"inventory-api","version","commit"}` |
| GET    | `/metrics` | Prometheus exposition (default Go collectors + custom histogram + lookup counter) |
| GET    | `/inventory/{sku}` | `{"sku","name","stock","updatedAt"}` (200) OR `{"error":"not found","sku"}` (404) |

The mock catalogue is in [`inventory.go`](inventory.go): five SKUs, hardcoded. SKU matching is case-insensitive (`GR-SHIRT-001` and `gr-shirt-001` both work). The data is in-memory only — there is no database, no upstream API, no state to persist.

## Local dev

Requires Go 1.23+.

```bash
go mod tidy
go test -race ./...
go run .                              # listens on :3000
curl localhost:3000/health
curl localhost:3000/inventory/GR-SHIRT-001
curl localhost:3000/metrics | head -30
```

## Container

```bash
docker build -t inventory-api:dev .
docker run --rm -p 3000:3000 inventory-api:dev
```

Final image size: ~17 MB — `gcr.io/distroless/static-debian12:nonroot` (only a libc-less binary + CA certs + the inventory-api binary). No shell. No package manager. Runs as uid `65532` (nonroot).

Trivy typically reports 0 OS-level CVEs against this base — meaningfully cleaner than the Node distroless used by `sample-app` because `static-debian12` doesn't ship a runtime.

## How it ships

`.github/workflows/inventory-api-ci.yml` runs on every PR and push to main that touches `apps/inventory-api/**`:

1. `go vet` + `go test -race` with coverage
2. SAST: CodeQL with the `go` language analysis
3. SCA: `govulncheck` against the module graph (reach-aware — only vulns in *called* code fail the build)
4. Docker build (multi-stage, distroless static)
5. Trivy image scan (HIGH/CRITICAL = fail, no ignorefile yet since static-debian12 has been clean)
6. Push to ACR via OIDC + the App UAMI (the SAME identity that `sample-app` uses — one identity, two apps).

After merge to main, ArgoCD picks up the image via `gitops/applications/inventory-api.yaml` and rolls the new version onto the cluster.

## Observability

The same `ServiceMonitor` pattern as sample-app surfaces:

- **In-cluster Prometheus (Layer 4)**: discovered automatically by prometheus-operator → metrics in the in-cluster Grafana via the `inventory-api-dashboard` ConfigMap.
- **Managed Prometheus (Layer 4b)**: configured via the `ama-metrics-prometheus-config` ConfigMap (extended in `observability/azure-managed/manifests/`).

Same `/metrics` endpoint, two pipelines.

## Cross-references

- App pattern parallels `apps/sample-app/` — read both side by side to see what is language-specific vs platform-shared.
- Kustomize manifests: `gitops/workloads/inventory-api/`.
- ArgoCD Application: `gitops/applications/inventory-api.yaml`.
- Observability resources: `observability/manifests/inventory-api/`.
