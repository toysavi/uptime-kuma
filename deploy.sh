#!/usr/bin/env bash
# ================================================================
#  deploy.sh — Uptime Kuma  |  Docker Compose
# ================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.yml"
ENV_FILE="${SCRIPT_DIR}/.env"

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

  [[ -f "${ENV_FILE}" ]]     && ok ".env found"    || err ".env not found: ${ENV_FILE}"
  [[ -f "${COMPOSE_FILE}" ]] && ok "compose found" || err "compose not found: ${COMPOSE_FILE}"

  [[ -f "${SCRIPT_DIR}/nginx/default.conf" ]] \
    && ok "nginx/default.conf found" \
    || err "nginx/default.conf missing — create it at nginx/default.conf"

  [[ -f "${SCRIPT_DIR}/nginx/certs/tls.crt" && -f "${SCRIPT_DIR}/nginx/certs/tls.key" ]] \
    && ok "SSL certs found" \
    || err "SSL certs missing — place tls.crt and tls.key in nginx/certs/"

  command -v docker &>/dev/null \
    && ok "docker found" \
    || err "docker not installed"

  if docker compose version &>/dev/null 2>&1; then
    ok "docker compose (plugin) found"
  elif command -v docker-compose &>/dev/null; then
    ok "docker-compose (standalone) found"
  else
    err "docker compose not found"
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
#  HEALTH WAIT
# ================================================================
wait_healthy() {
  local container="$1"
  local elapsed=0
  local spinner=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
  local si=0

  while (( elapsed < HEALTH_TIMEOUT )); do
    local status
    status=$(docker inspect --format '{{.State.Status}}' "${container}" 2>/dev/null || echo "gone")

    if [[ "${status}" == "exited" || "${status}" == "gone" || "${status}" == "dead" ]]; then
      printf "\r  ${RED}✖${RESET}  %-60s\n" "${container} exited unexpectedly"
      return 1
    fi

    local health
    health=$(docker inspect \
      --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
      "${container}" 2>/dev/null || echo "none")

    case "${health}" in
      healthy)
        printf "\r  ${GREEN}✔${RESET}  %-60s\n" "${container} is healthy"
        return 0 ;;
      none)
        if [[ "${status}" == "running" ]]; then
          printf "\r  ${GREEN}✔${RESET}  %-60s\n" "${container} is running"
          return 0
        fi ;;
      unhealthy)
        printf "\r  ${RED}✖${RESET}  %-60s\n" "${container} is unhealthy"
        return 1 ;;
    esac

    printf "\r  ${CYAN}${spinner[$((si % 10))]}${RESET}  ${DIM}Waiting for ${container} … ${elapsed}s / ${HEALTH_TIMEOUT}s${RESET}"
    sleep "${HEALTH_INTERVAL}"
    (( elapsed += HEALTH_INTERVAL ))
    (( si++ ))
  done

  printf "\r  ${RED}✖${RESET}  %-60s\n" "Timeout waiting for ${container}"
  return 1
}

# ================================================================
#  COMMANDS
# ================================================================
cmd_up() {
  section "Pulling images"
  dc pull

  section "Starting services"
  dc up -d --remove-orphans

  section "Waiting for services to be healthy"
  wait_healthy kuma-db
  wait_healthy kuma-app
  wait_healthy kuma-nginx

  section "Status"
  dc ps
  echo ""
  ok "Deploy complete!"
  info "Uptime Kuma  →  https://kuma.phillipbank.com.kh"
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

cmd_update() {
  section "Pulling latest images"
  dc pull

  section "Re-creating updated services"
  dc up -d --remove-orphans

  section "Waiting for services"
  wait_healthy kuma-db
  wait_healthy kuma-app
  wait_healthy kuma-nginx

  section "Status"
  dc ps
  echo ""
  ok "Update complete."
}

cmd_rolling() {
  local services=("kuma-db" "kuma-app" "kuma-nginx")
  [[ -n "${1:-}" ]] && services=("$1") && info "Targeting: $1"

  section "Pulling latest images"
  dc pull

  for svc in "${services[@]}"; do
    section "Rolling update: ${svc}"

    local old_id
    old_id=$(dc ps -q "${svc}" 2>/dev/null | head -1 || true)

    if [[ -z "${old_id}" ]]; then
      warn "  ${svc} not running — starting fresh"
      dc up -d --no-deps "${svc}"
      local new_id
      new_id=$(dc ps -q "${svc}" 2>/dev/null | head -1 || true)
      [[ -n "${new_id}" ]] && wait_healthy "${new_id}" || err "${svc} failed to start"
      continue
    fi

    info "  Old container: ${old_id:0:12}"

    local has_ports
    has_ports=$(docker inspect "${old_id}" \
      --format '{{range $p,$b := .HostConfig.PortBindings}}{{$p}}{{end}}' 2>/dev/null || true)

    if [[ -n "${has_ports}" ]]; then
      # Port-bound: recreate (brief restart), rollback on failure
      dc up -d --no-deps --force-recreate "${svc}"
      local new_id
      new_id=$(dc ps -q "${svc}" 2>/dev/null | head -1 || true)
      info "  New container: ${new_id:0:12}"

      if ! wait_healthy "${new_id}"; then
        warn "  Rolling back ${svc}…"
        docker start "${old_id}" 2>/dev/null && warn "  Rolled back to ${old_id:0:12}" \
          || warn "  Could not roll back — manual intervention needed"
        exit 1
      fi
    else
      # No ports: rename old → start new → verify → remove old
      local old_name backup_name
      old_name=$(docker inspect "${old_id}" --format '{{.Name}}' 2>/dev/null | sed 's|^/||')
      backup_name="${old_name}_old_$$"

      docker rename "${old_id}" "${backup_name}" 2>/dev/null || true
      dc up -d --no-deps --force-recreate "${svc}"

      local new_id
      new_id=$(dc ps -q "${svc}" 2>/dev/null | head -1 || true)
      info "  New container: ${new_id:0:12}"

      if wait_healthy "${new_id}"; then
        docker stop "${old_id}" 2>/dev/null || true
        docker rm   "${old_id}" 2>/dev/null || true
        ok "  Old container removed"
      else
        warn "  Rolling back ${svc}…"
        docker stop   "${new_id}"  2>/dev/null || true
        docker rm     "${new_id}"  2>/dev/null || true
        docker rename "${backup_name}" "${old_name}" 2>/dev/null || true
        docker start  "${old_id}"  2>/dev/null && warn "  Rolled back to ${old_id:0:12}" \
          || warn "  Could not roll back — manual intervention needed"
        exit 1
      fi
    fi

    ok "  ${svc} updated successfully"
    echo ""
  done

  section "Final status"
  dc ps
  echo ""
  ok "Rolling update complete."
}

cmd_logs() {
  dc logs -f --tail=50 "$@"
}

cmd_status() {
  section "Service status"
  dc ps
}

cmd_destroy() {
  warn "This will stop and remove all containers, networks and volumes."
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
  echo "    up               — Pull images and start all services  (default)"
  echo "    update           — Pull latest images and recreate services"
  echo "    rolling [svc]    — Zero-downtime rolling update"
  echo "    down             — Stop all services"
  echo "    restart          — Restart all services"
  echo "    logs [svc]       — Follow logs"
  echo "    status           — Show running containers"
  echo "    destroy          — Stop and remove everything including volumes"
  echo ""
  echo "  Services:  kuma-db  |  kuma-app  |  kuma-nginx"
  echo ""
}

# ================================================================
#  ENTRY
# ================================================================
COMMAND="${1:-up}"
preflight

case "${COMMAND}" in
  up)      cmd_up                             ;;
  update)  cmd_update                         ;;
  rolling) shift; cmd_rolling "${1:-}"        ;;
  down)    cmd_down                           ;;
  restart) cmd_restart                        ;;
  logs)    shift; cmd_logs "$@"               ;;
  status)  cmd_status                         ;;
  destroy) cmd_destroy                        ;;
  *)       usage; exit 1                      ;;
esac
