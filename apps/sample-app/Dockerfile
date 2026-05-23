# Multi-stage Dockerfile.
#
# Stage 1 (deps): install only production deps in a deterministic, reproducible
# layer that depends solely on package*.json. Cached by Docker as long as those
# files don't change.
#
# Stage 2 (runtime): minimal distroless image — no shell, no package manager,
# no curl. The blast radius of a compromised container is far smaller than a
# full Debian/Alpine base. Trivy will report ~0 OS CVEs against distroless.

ARG NODE_VERSION=20

# --- Stage 1: install prod dependencies ---------------------------------------
FROM node:${NODE_VERSION}-bookworm-slim AS deps
WORKDIR /app
COPY package.json package-lock.json* ./
RUN npm ci --omit=dev --ignore-scripts

# --- Stage 2: distroless runtime ----------------------------------------------
FROM gcr.io/distroless/nodejs20-debian12 AS runtime
WORKDIR /app
ENV NODE_ENV=production
ENV PORT=3000

# Copy resolved node_modules from the deps stage, then app source.
COPY --from=deps /app/node_modules ./node_modules
COPY src ./src
COPY package.json ./

USER nonroot
EXPOSE 3000

# Distroless has no shell, so we use the JSON exec form.
CMD ["src/index.js"]
