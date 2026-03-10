# ================================================================
#  Dockerfile — Custom Uptime Kuma image
#
#  Builds from the official Uptime Kuma source and bakes in
#  MySQL connection defaults via ARGs (overridable at build time).
#
#  Build:
#    docker build \
#      --build-arg DB_HOST=kuma-mysql \
#      --build-arg DB_NAME=uptimekuma \
#      -t my-uptime-kuma:latest .
#
#  Or simply:  docker build -t my-uptime-kuma:latest .
#  (defaults below will be used)
# ================================================================

# ── Stage 1: Build (install deps + compile frontend) ─────────────
FROM node:18-alpine AS builder

WORKDIR /app

# Install git to clone source
RUN apk add --no-cache git

# Clone official Uptime Kuma source at a pinned version tag
ARG KUMA_VERSION=2.2.0
RUN git clone --depth 1 --branch "${KUMA_VERSION}" \
    https://github.com/louislam/uptime-kuma.git .

# Install all dependencies (including devDependencies for build)
RUN npm ci --no-audit

# Build the frontend (Vue → dist/)
RUN npm run build

# Remove devDependencies — keep only production deps
RUN npm prune --production

# ── Stage 2: Runtime ─────────────────────────────────────────────
FROM node:18-alpine AS runtime

# ── Build-time DB defaults (override with --build-arg) ───────────
ARG DB_TYPE=mysql
ARG DB_HOST=kuma-mysql
ARG DB_PORT=3306
ARG DB_NAME=uptimekuma
ARG DB_USER=kuma
ARG DB_PASSWORD=kumapass

# ── Bake defaults into the image as ENV ──────────────────────────
# These become the fallback values if no environment variable is
# passed at `docker run` / `docker compose up` time.
# Runtime ENV vars always override these.
ENV DB_TYPE=${DB_TYPE} \
    DB_HOST=${DB_HOST} \
    DB_PORT=${DB_PORT} \
    DB_NAME=${DB_NAME} \
    DB_USER=${DB_USER} \
    DB_PASSWORD=${DB_PASSWORD} \
    # Uptime Kuma data directory
    DATA_DIR=/app/data \
    # Node environment
    NODE_ENV=production

# Runtime dependencies only
RUN apk add --no-cache \
    # Required by Uptime Kuma for ping/ICMP monitors
    iputils \
    # Required for DNS monitors
    bind-tools \
    # curl used in healthcheck
    curl \
    # tini for proper PID 1 signal handling
    tini

WORKDIR /app

# Copy built artifacts from builder stage
COPY --from=builder /app/node_modules ./node_modules
COPY --from=builder /app/dist         ./dist
COPY --from=builder /app/server       ./server
COPY --from=builder /app/public       ./public
COPY --from=builder /app/package.json ./package.json
COPY --from=builder /app/package-lock.json ./package-lock.json
COPY --from=builder /app/db           ./db

# Persistent data volume
VOLUME ["/app/data"]

EXPOSE 3001

HEALTHCHECK --interval=10s --timeout=5s --start-period=30s --retries=5 \
  CMD curl -sf http://localhost:3001/api/status-page/heartbeat || exit 1

# Use tini as init so signals (SIGTERM etc.) propagate correctly
ENTRYPOINT ["/sbin/tini", "--"]
CMD ["node", "server/server.js"]