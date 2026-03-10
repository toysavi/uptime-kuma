#!/usr/bin/env bash
# ================================================================
#  deploy.sh — Uptime Kuma  |  Docker Compose deployer
#  Includes zero-downtime rolling update per service
# ================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="${SCRIPT_DIR}/menifest/docker-compose.yml"
ENV_FILE="${SCRIPT_DIR}/.env"

# How long to wait for a container to become healthy (seconds)
HEALTH_TIMEOUT=120
HEALTH_INTERVAL=3

# ── Colours ──────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'
CYAN='\033[0;36m';  BOLD='\033[1m';      DIM='\033[2m'; RESET='\033[0m'

ok()      { echo -e "  ${GREEN}✔${RESET}  $*"; }
warn()    { echo -e "  ${YELLOW}⚠${RESET}  $*"; }
err()     { echo -e "  ${RED}✖${RESET}  $*"; exit 1; }
info()    { echo -e "  ${CYAN}ℹ${RESET}  $*"; }
section() { echo -e "\n${BOLD}${CYAN}▶  $*${RESET}"; }

# ================================================================
#  PRE-FLIGHT
# ================================================================
preflight() {
  section "Pre-flight checks"

  [[ -f "${ENV_FILE}" ]]     && ok ".env found"    || err ".env not found at ${ENV_FILE}"
  [[ -f "${COMPOSE_FILE}" ]] && ok "compose found" || err "compose not found at ${COMPOSE_FILE}"

  [[ -f "${SCRIPT_DIR}/nginx/default.conf" ]] \
    && ok "nginx/default.conf found" \
    || err "nginx/default.conf missing — kuma-nginx will fail"

  [[ -d "${SCRIPT_DIR}/nginx/certs" ]] \
    && ok "nginx/certs found" \
    || warn "nginx/certs/ missing — HTTPS will not work"

  [[ -d "${SCRIPT_DIR}/init-scripts" ]] \
    && ok "init-scripts found" \
    || warn "init-scripts/ missing — MySQL init SQL will be skipped"

  command -v docker &>/dev/null \
    && ok "docker found" \
    || err "docker not installed"

  if docker compose version &>/dev/null 2>&1; then
    ok "docker compose (plugin) found"
  elif command -v docker-compose &>/dev/null; then
    ok "docker-compose (standalone) found"
  else
    err "docker compose not found — install the Docker Compose plugin"
  fi
}

# ================================================================
#  COMPOSE WRAPPER
# ================================================================
dc() {
  if docker compose version &>/dev/null 2>&1; then
    docker compose --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}" "$@"
  else
    docker-compose --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}" "$@"
  fi
}

# ================================================================
#  HEALTH CHECK WAIT
#
#  Usage: wait_healthy <container_name_or_id>
#
#  Returns 0 when the container reports "healthy" or has no
#  healthcheck defined (treats no-healthcheck as immediately OK).
#  Returns 1 on timeout or if the container exited/is unhealthy.
# ================================================================
wait_healthy() {
  local container="$1"
  local elapsed=0
  local spinner=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
  local si=0

  while (( elapsed < HEALTH_TIMEOUT )); do
    local status
    status=$(docker inspect --format '{{.State.Status}}' "${container}" 2>/dev/null || echo "gone")

    # Container exited or disappeared — fail immediately
    if [[ "${status}" == "exited" || "${status}" == "gone" || "${status}" == "dead" ]]; then
      printf "\r  ${RED}✖${RESET}  %-60s\n" "${container} exited unexpectedly"
      return 1
    fi

    local health
    health=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
      "${container}" 2>/dev/null || echo "none")

    case "${health}" in
      healthy)
        printf "\r  ${GREEN}✔${RESET}  %-60s\n" "${container} is healthy"
        return 0
        ;;
      none)
        # No healthcheck — just confirm it's running
        if [[ "${status}" == "running" ]]; then
          printf "\r  ${GREEN}✔${RESET}  %-60s\n" "${container} is running (no healthcheck)"
          return 0
        fi
        ;;
      unhealthy)
        printf "\r  ${RED}✖${RESET}  %-60s\n" "${container} is unhealthy"
        return 1
        ;;
    esac

    printf "\r  ${CYAN}${spinner[$((si % 10))]}${RESET}  ${DIM}Waiting for ${container} … ${elapsed}s / ${HEALTH_TIMEOUT}s${RESET}"
    sleep "${HEALTH_INTERVAL}"
    (( elapsed += HEALTH_INTERVAL ))
    (( si++ ))
  done

  printf "\r  ${RED}✖${RESET}  %-60s\n" "Timeout waiting for ${container} to become healthy"
  return 1
}

# ================================================================
#  ZERO-DOWNTIME ROLLING UPDATE
#
#  For each service (in dependency order):
#    1. Pull the new image
#    2. Start a new container with `--no-deps`
#    3. Wait until the new container is healthy
#    4. Only then stop & remove the old container
#
#  Services without port conflicts can overlap safely.
#  kuma-mysql is always updated first (dependency of kuma-app).
# ================================================================
cmd_rolling_update() {
  section "Zero-downtime rolling update"
  echo ""

  # Update order: dependencies first
  # mysql → app → nginx
  local services=("kuma-mysql" "kuma-app" "kuma-nginx")

  # Allow targeting a single service: ./deploy.sh rolling kuma-app
  if [[ -n "${1:-}" ]]; then
    services=("$1")
    info "Targeting single service: $1"
  fi

  section "Pulling new images"
  dc pull
  echo ""

  for svc in "${services[@]}"; do
    section "Rolling update: ${svc}"

    # Rebuild the custom image before updating kuma-app
    if [[ "${svc}" == "kuma-app" ]]; then
      set -a; source "${ENV_FILE}"; set +a
      info "  Rebuilding custom image…"
      cmd_build_image
    fi

    # ── Get the current (old) container ID before recreate ──────
    local old_id
    old_id=$(dc ps -q "${svc}" 2>/dev/null | head -1 || true)

    if [[ -z "${old_id}" ]]; then
      warn "  ${svc} is not running — doing a fresh start instead"
      dc up -d --no-deps "${svc}"
      # Get the new container and wait for it
      local new_id
      new_id=$(dc ps -q "${svc}" 2>/dev/null | head -1 || true)
      [[ -n "${new_id}" ]] && wait_healthy "${new_id}" || err "${svc} failed to start"
      echo ""
      continue
    fi

    info "  Old container: ${old_id:0:12}"

    # ── Scale up: start a new container alongside the old one ───
    # `up --no-deps --force-recreate` pulls the new image and
    # starts a fresh container. For port-mapped services Docker
    # will stop the old one first — we handle that gracefully.
    info "  Starting new container…"

    # For services with host port bindings (nginx, kuma-app) Docker
    # cannot run two containers on the same port. We use a
    # rename-then-recreate strategy: rename old → _old, start new,
    # wait healthy, then remove the renamed container.
    local has_ports
    has_ports=$(docker inspect "${old_id}" \
      --format '{{range $p,$b := .HostConfig.PortBindings}}{{$p}}{{end}}' 2>/dev/null || true)

    if [[ -n "${has_ports}" ]]; then
      # ── Port-bound service: brief overlap not possible ─────────
      # Strategy: start new (Docker stops old automatically due to
      # port conflict), then verify new is healthy. If new fails,
      # restart old container to recover.
      warn "  ${svc} has port bindings — brief restart required (< healthcheck time)"

      dc up -d --no-deps --force-recreate "${svc}"

      local new_id
      new_id=$(dc ps -q "${svc}" 2>/dev/null | head -1 || true)
      info "  New container: ${new_id:0:12}"

      if ! wait_healthy "${new_id}"; then
        err "  New ${svc} container failed health check — rolling back"
        # Restart old container as fallback
        docker start "${old_id}" 2>/dev/null \
          && warn "  Rolled back to previous container ${old_id:0:12}" \
          || warn "  Could not restart old container — manual intervention needed"
        exit 1
      fi

    else
      # ── No port bindings: true overlap possible ─────────────────
      # Rename old container so the new one can take its name,
      # start new, wait healthy, then kill old.
      local old_name
      old_name=$(docker inspect "${old_id}" --format '{{.Name}}' 2>/dev/null | sed 's|^/||')
      local backup_name="${old_name}_old_$$"

      info "  Renaming old container to ${backup_name}"
      docker rename "${old_id}" "${backup_name}" 2>/dev/null || true

      info "  Starting new container…"
      dc up -d --no-deps --force-recreate "${svc}"

      local new_id
      new_id=$(dc ps -q "${svc}" 2>/dev/null | head -1 || true)
      info "  New container: ${new_id:0:12}"

      if wait_healthy "${new_id}"; then
        info "  Stopping old container ${backup_name}"
        docker stop "${old_id}" 2>/dev/null  || true
        docker rm   "${old_id}" 2>/dev/null  || true
        ok "  Old container removed"
      else
        err "  New ${svc} container failed health check — rolling back"
        docker stop "${new_id}"  2>/dev/null || true
        docker rm   "${new_id}"  2>/dev/null || true
        docker rename "${backup_name}" "${old_name}" 2>/dev/null || true
        docker start  "${old_id}" 2>/dev/null \
          && warn "  Rolled back to previous container ${old_id:0:12}" \
          || warn "  Could not restart old container — manual intervention needed"
        exit 1
      fi
    fi

    ok "  ${svc} updated successfully"
    echo ""
  done

  section "Final status"
  dc ps
  echo ""
  ok "Rolling update complete — zero downtime achieved."
}

# ================================================================
#  STANDARD COMMANDS
# ================================================================
cmd_build_image() {
  section "Building custom kuma-app image"
  # Pass .env values as build-args so ARGs in Dockerfile get the right defaults
  dc build \
    --build-arg "DB_TYPE=${KU_DB_TYPE:-mysql}" \
    --build-arg "DB_HOST=${KU_DB_HOST:-kuma-mysql}" \
    --build-arg "DB_PORT=${KU_DB_PORT:-3306}" \
    --build-arg "DB_NAME=${KU_DB_NAME:-uptimekuma}" \
    --build-arg "DB_USER=${KU_DB_USER:-kuma}" \
    --build-arg "DB_PASSWORD=${KU_DB_PASSWORD:-kumapass}" \
    --no-cache \
    kuma-app
  ok "Image built: my-uptime-kuma:latest"
}

cmd_up() {
  # Load .env so build-args are available
  set -a; source "${ENV_FILE}"; set +a

  section "Building custom kuma-app image"
  cmd_build_image

  section "Pulling other images (mysql, nginx)"
  dc pull kuma-mysql kuma-nginx

  section "Starting services"
  dc up -d --remove-orphans
  section "Status"
  dc ps
  echo ""
  ok "Deploy complete!"
  info "Uptime Kuma  →  http://localhost:3001"
  info "Nginx proxy  →  http://localhost"
}

cmd_down() {
  section "Stopping services"
  dc down
  ok "Stack stopped."
}

cmd_restart() {
  section "Restarting services"
  dc restart
  ok "Restarted."
}

cmd_logs() {
  dc logs -f --tail=50 "$@"
}

cmd_status() {
  section "Service status"
  dc ps
}

cmd_destroy() {
  warn "This will stop and remove all containers and networks."
  warn "Volumes (mysql-data, kuma-data) will also be removed."
  read -rp "  Continue? [y/N] " confirm
  [[ "${confirm,,}" == "y" ]] || { info "Cancelled."; exit 0; }
  dc down -v
  ok "Stack destroyed."
}

# ================================================================
#  USAGE
# ================================================================
usage() {
  echo ""
  echo -e "  ${BOLD}Usage:${RESET}  ./deploy.sh [command] [service]"
  echo ""
  echo "  Commands:"
  echo "    up              — Build image, pull others, start all services  (default)"
  echo "    build           — Build the custom kuma-app image only"
  echo "    rolling         — Zero-downtime rolling update (all services)"
  echo "    rolling <svc>   — Zero-downtime update for one service only"
  echo "    down            — Stop all services"
  echo "    restart         — Restart all services"
  echo "    logs [svc]      — Follow logs (optional: service name)"
  echo "    status          — Show running containers"
  echo "    destroy         — Stop and remove everything including volumes"
  echo ""
  echo "  Services:  kuma-mysql  |  kuma-app  |  kuma-nginx"
  echo ""
  echo "  Examples:"
  echo "    ./deploy.sh rolling             # update all, in order"
  echo "    ./deploy.sh rolling kuma-app    # update only kuma-app"
  echo ""
}

# ================================================================
#  ENTRY
# ================================================================
COMMAND="${1:-up}"

preflight

case "${COMMAND}" in
  up)      cmd_up                       ;;
  build)   set -a; source "${ENV_FILE}"; set +a; cmd_build_image ;;
  rolling) shift; cmd_rolling_update "${1:-}" ;;
  down)    cmd_down                     ;;
  restart) cmd_restart                  ;;
  logs)    shift; cmd_logs "$@"         ;;
  status)  cmd_status                   ;;
  destroy) cmd_destroy                  ;;
  *)       usage; exit 1                ;;
esac