# globalretail-sample-app

A deliberately tiny Express app whose only purpose is to exercise the Layer 2 CI/CD pipeline end-to-end. Two routes, two test files, one Dockerfile. The code is intentionally not the point — the pipeline that builds, tests, scans, and ships it is.

## Routes

| Method | Path       | Response |
|--------|------------|----------|
| GET    | `/health`  | `{ status: "ok", uptimeSeconds: N }` |
| GET    | `/version` | `{ name: "globalretail-sample-app", version, commit }` |

Both `version` and `commit` come from `APP_VERSION` / `APP_COMMIT` env vars (set by the CI workflow from the GitHub SHA and ref).

## Local dev

```bash
npm install
npm test          # jest + supertest, with coverage gate at 80%
npm start         # listens on :3000
curl localhost:3000/health
```

## Container

```bash
docker build -t globalretail-sample-app:dev .
docker run --rm -p 3000:3000 globalretail-sample-app:dev
```

The runtime layer is `gcr.io/distroless/nodejs20-debian12` — no shell, no package manager. Trivy will typically report ~0 OS-level CVEs against this base. If you need to shell in for debugging, build with `:debug` tag of the distroless image (not done here on purpose: keeping the prod image minimal is the lesson).

## How it ships

This folder is meant to be the **entire contents of a separate GitHub repo** (e.g. `iscoct/globalretail-sample-app`). When you push to that repo, `.github/workflows/ci.yml` runs the multi-stage pipeline:

1. Unit tests (`npm test`)
2. SAST with CodeQL
3. SCA with `npm audit` (and Dependabot in the background)
4. Docker build
5. Image scan with Trivy
6. Push to ACR via OIDC federated identity

See `../README.md` (Layer 2 sub-README) for the full narrative.
