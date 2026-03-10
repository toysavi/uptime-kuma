#!/usr/bin/env bash
# ================================================================
#  deploy.sh — Uptime Kuma / Docker Swarm Stack Manager
#  Background operations + in-place table refresh (no full clear)
# ================================================================
set -uo pipefail

STACK_NAME="uptime"
COMPOSE_FILE="docker-compose.yml"
# COMPOSE_FILE= "./menifest/*.yml"
REFRESH_INTERVAL=2   # seconds between table refresh

# ── Colours ─────────────────────────────────────────────────────
RED='\033[0;31m';    GREEN='\033[0;32m';  YELLOW='\033[1;33m'
BLUE='\033[0;34m';   CYAN='\033[0;36m';  WHITE='\033[1;37m'
MAGENTA='\033[0;35m'; BOLD='\033[1m';    DIM='\033[2m'; RESET='\033[0m'

# ── Box-drawing (MySQL +---+ style) ─────────────────────────────
TL='+'; TR='+'; BL='+'; BR='+'; H='-'; V='|'
tl='+'; tr='+'; bl='+'; br='+'; h='-'; v='|'
tm='+'; bm='+'; lm='+'; rm='+'; x='+'

# ── Terminal cursor control ──────────────────────────────────────
_cursor_hide()    { printf '\033[?25l'; }
_cursor_show()    { printf '\033[?25h'; }
_cursor_save()    { printf '\033[s';    }
_cursor_restore() { printf '\033[u';    }
_erase_down()     { printf '\033[J';    }   # erase from cursor to end of screen
_move_up()        { printf "\033[%dA" "$1"; }

# ================================================================
#  Utility helpers
# ================================================================
section() { echo -e "\n${BOLD}${BLUE}▶  $*${RESET}"; }
ok()      { echo -e "  ${GREEN}✔${RESET}  $*"; }
warn()    { echo -e "  ${YELLOW}⚠${RESET}  $*"; }
err()     { echo -e "  ${RED}✖${RESET}  $*"; }
info()    { echo -e "  ${CYAN}ℹ${RESET}  $*"; }
pause()   { echo ""; read -rp "  Press [Enter] to return to menu…"; }

print_banner() {
  clear
  echo -e "${CYAN}"
  cat <<'BANNER'
  ██╗   ██╗██████╗ ████████╗██╗███╗   ███╗███████╗    ██╗  ██╗██╗   ██╗███╗   ███╗ █████╗
  ██║   ██║██╔══██╗╚══██╔══╝██║████╗ ████║██╔════╝    ██║ ██╔╝██║   ██║████╗ ████║██╔══██╗
  ██║   ██║██████╔╝   ██║   ██║██╔████╔██║█████╗      █████╔╝ ██║   ██║██╔████╔██║███████║
  ██║   ██║██╔═══╝    ██║   ██║██║╚██╔╝██║██╔══╝      ██╔═██╗ ██║   ██║██║╚██╔╝██║██╔══██║
  ╚██████╔╝██║        ██║   ██║██║ ╚═╝ ██║███████╗    ██║  ██╗╚██████╔╝██║ ╚═╝ ██║██║  ██║
   ╚═════╝ ╚═╝        ╚═╝   ╚═╝╚═╝     ╚═╝╚══════╝    ╚═╝  ╚═╝ ╚═════╝ ╚═╝     ╚═╝╚═╝  ╚═╝
BANNER
  echo -e "${RESET}"
}

# ================================================================
#  Table renderer — MySQL +-----+-----+ style
#
#  Matches the exact visual of:
#    mysql> SELECT user, host FROM mysql.user;
#    +-------+------+
#    | user  | host |
#    +-------+------+
#    | kuma  | %    |
#    +-------+------+
# ================================================================
print_table_skeleton() {
  local title="$1" widths_csv="$2" headers_csv="$3"
  IFS=',' read -ra widths  <<< "${widths_csv}"
  IFS=',' read -ra headers <<< "${headers_csv}"

  _tbl_border() {
    printf "  \033[36m+"
    for w in "${widths[@]}"; do printf '%*s' $((w+2)) '' | tr ' ' '-'; printf "+"; done
    printf "\033[0m\n"
  }

  printf "\n"
  printf "  \033[1;37m%s\033[0m\n" "${title}"
  _tbl_border
  printf "  \033[36m|\033[0m"
  for i in "${!headers[@]}"; do
    printf " \033[1;37m%-*s\033[0m \033[36m|\033[0m" "${widths[$i]}" "${headers[$i]}"
  done
  printf "\n"
  _tbl_border
}

print_table_rows() {
  local widths_csv="$1" max_rows="$2"
  shift 2
  local rows=("$@")
  IFS=',' read -ra widths <<< "${widths_csv}"

  _tbl_border_r() {
    printf "  \033[36m+"
    for w in "${widths[@]}"; do printf '%*s' $((w+2)) '' | tr ' ' '-'; printf "+"; done
    printf "\033[0m\n"
  }

  local count=0
  for row in "${rows[@]}"; do
    (( count >= max_rows )) && break
    IFS='|' read -ra cells <<< "${row}"
    printf "  \033[36m|\033[0m"
    for i in "${!widths[@]}"; do
      local cell="${cells[$i]:-}"
      local c="\033[1;37m"   # default white
      case "${cell}" in
        running|Running|healthy|Healthy|Ready|Active|OK|complete|Complete|Scheduled|scheduled)
          c="\033[0;32m" ;;
        preparing|Preparing|Updating|updating|Starting|starting|Pending|pending|Converging)
          c="\033[1;33m" ;;
        failed|Failed|Error|error|shutdown|Shutdown|rejected|Rejected|dead|Dead)
          c="\033[0;31m" ;;
        Stack|stack)     c="\033[0;35m" ;;
        Compose|compose) c="\033[0;34m" ;;
        *"/"*)
          local num="${cell%%/*}" den="${cell##*/}"
          if [[ "${num}" =~ ^[0-9]+$ && "${den}" =~ ^[0-9]+$ ]]; then
            [[ "${num}" == "${den}" && "${num}" != "0" ]] \
              && c="\033[0;32m" || c="\033[1;33m"
          fi ;;
      esac
      printf " ${c}%-*s\033[0m \033[36m|\033[0m" "${widths[$i]}" "${cell}"
    done
    printf "\n"
    (( count++ ))
  done
  while (( count < max_rows )); do
    printf "  \033[36m|\033[0m"
    for i in "${!widths[@]}"; do
      printf " %-*s \033[36m|\033[0m" "${widths[$i]}" ""
    done
    printf "\n"
    (( count++ ))
  done
  _tbl_border_r
}

# ── legacy wrapper ────────────────────────────────────────────────
print_table() {
  local title="$1" widths_csv="$2" headers_csv="$3"
  shift 3
  print_table_skeleton "${title}" "${widths_csv}" "${headers_csv}"
  print_table_rows     "${widths_csv}" 99 "$@"
}

# ================================================================
#  Data collection — entire Docker Swarm cluster
# ================================================================

_swarm_active() {
  docker info 2>/dev/null | grep -E "^\s*Swarm:" | awk '{print $2}' || echo "inactive"
}

_stack_exists() {
  docker stack ls 2>/dev/null | awk 'NR>1{print $1}' | grep -q "^${STACK_NAME}$" \
    && echo "yes" || echo "no"
}

# ================================================================
#  BUILD PHASE
#
#  _build_phase  <compose_file> <stack_name> <state_file>
#
#  1. Validates compose file (docker compose config)
#  2. Extracts: services + images, networks, ports
#  3. Pulls every image with live progress
#  4. Writes state file sections:
#       [containers]   stack|svc_name|—|—|0/N|Scheduled
#       [networks]     net_name|overlay|swarm|—|0
#       [ports]        svc_name|Stack|stack|*|host_port|cont_port|proto
#  5. Returns 0 on success, 1 on any failure
#
#  Deploy reads this file so tables are pre-populated before
#  docker stack deploy runs. Rows transition from Scheduled →
#  Starting → Running as live docker data takes over.
# ================================================================
_build_phase() {
  local compose_file="$1"
  local stack_name="$2"
  local state_file="$3"

  # ── Step 1: Validate + resolve compose to canonical YAML ─────
  echo ""
  info "  Validating compose file…"
  local resolved
  if ! resolved=$(docker compose -f "${compose_file}" config 2>/tmp/build_err.txt); then
    err "  Compose validation failed:"
    sed 's/^/    /' /tmp/build_err.txt >&2
    rm -f /tmp/build_err.txt
    return 1
  fi
  ok "  Compose file valid."

  # ── Step 2: Parse services ────────────────────────────────────
  echo ""
  info "  Parsing services…"

  # Extract service names
  local services=()
  while IFS= read -r svc; do
    [[ -n "${svc}" ]] && services+=("${svc}")
  done < <(docker compose -f "${compose_file}" config --services 2>/dev/null)

  if [[ ${#services[@]} -eq 0 ]]; then
    err "  No services found in compose file."; return 1
  fi

  # For each service: get image + replicas + ports
  declare -A svc_image svc_replicas svc_ports
  for svc in "${services[@]}"; do
    # Image
    local img
    img=$(docker compose -f "${compose_file}" config 2>/dev/null \
      | awk "/^  ${svc}:/{found=1} found && /^    image:/{print \$2; exit}")
    [[ -z "${img}" ]] && img="${stack_name}_${svc}:latest"
    svc_image["${svc}"]="${img}"

    # Replicas (default 1 for swarm)
    local reps
    reps=$(docker compose -f "${compose_file}" config 2>/dev/null \
      | awk "/^  ${svc}:/{found=1} found && /^      replicas:/{print \$2; exit}")
    [[ -z "${reps}" || ! "${reps}" =~ ^[0-9]+$ ]] && reps=1
    svc_replicas["${svc}"]="${reps}"

    # Published ports
    local ports_raw
    ports_raw=$(docker compose -f "${compose_file}" config 2>/dev/null \
      | awk "/^  ${svc}:/{s=1} s && /^    ports:/{p=1; next} p && /^      -/{print; next} p && /^    [^ ]/{p=0} !s{next}")
    svc_ports["${svc}"]="${ports_raw}"

    printf "  %b  %-30s %b%s%b\n" "${DIM}" "${svc}" "${WHITE}" "${img}" "${RESET}"
  done

  # ── Step 3: Parse networks ────────────────────────────────────
  echo ""
  info "  Parsing networks…"
  local networks=()
  while IFS= read -r net; do
    [[ -n "${net}" ]] && networks+=("${net}")
  done < <(docker compose -f "${compose_file}" config 2>/dev/null \
    | awk '/^networks:/{found=1; next} found && /^  [a-z]/{gsub(/:$/,"",$1); print $1} found && /^[^ ]/{exit}')
  for net in "${networks[@]}"; do
    printf "  %b  network: %b%s%b\n" "${DIM}" "${CYAN}" "${stack_name}_${net}" "${RESET}"
  done
  [[ ${#networks[@]} -eq 0 ]] && info "  (no explicit networks defined)"

  # ── Step 4: Pull all images ───────────────────────────────────
  echo ""
  section "  Pulling images…"
  echo ""
  local pull_failed=0
  for svc in "${services[@]}"; do
    local img="${svc_image[${svc}]}"
    printf "  %b  %-20s%b  pulling %b%s%b\n" \
      "${BOLD}${WHITE}" "${svc}" "${RESET}" "${CYAN}" "${img}" "${RESET}"
    if ! docker pull "${img}" 2>&1 | sed 's/^/    /'; then
      warn "  Could not pull ${img} — may be a locally-built image, continuing…"
      pull_failed=1
    fi
    echo ""
  done
  [[ ${pull_failed} -eq 0 ]] && ok "  All images ready." || warn "  Some images not pulled (will use local or build)."

  # ── Step 5: Write state file ─────────────────────────────────
  echo ""
  info "  Writing build state to ${state_file}…"

  {
    echo "[meta]"
    echo "stack=${stack_name}"
    echo "compose=${compose_file}"
    echo "built_at=$(date '+%Y-%m-%d %H:%M:%S')"
    echo ""

    echo "[containers]"
    for svc in "${services[@]}"; do
      local reps="${svc_replicas[${svc}]}"
      # STACK | SVC_NAME | — | — | 0/N | Scheduled
      echo "${stack_name}|${stack_name}_${svc}|—|—|0/${reps}|Scheduled"
    done
    echo ""

    echo "[networks]"
    # Always include ingress
    echo "ingress|overlay|swarm|10.0.0.0/24|0"
    for net in "${networks[@]}"; do
      echo "${stack_name}_${net}|overlay|swarm|—|0"
    done
    echo ""

    echo "[ports]"
    for svc in "${services[@]}"; do
      local ports_raw="${svc_ports[${svc}]:-}"
      [[ -z "${ports_raw}" ]] && continue
      while IFS= read -r pline; do
        # pline like: "- target: 3001" or "- '3001:3001'" or "- 80:80"
        pline="${pline//- /}"
        pline="${pline//\'/}"
        pline="${pline// /}"
        [[ -z "${pline}" ]] && continue
        # Handle "host:container/proto" format
        local host_port cont_port proto="tcp"
        [[ "${pline}" == *"/udp" ]] && proto="udp"
        pline="${pline%/*}"
        if [[ "${pline}" == *":"* ]]; then
          host_port="${pline%%:*}"
          cont_port="${pline##*:}"
        else
          host_port="${pline}"
          cont_port="${pline}"
        fi
        [[ -z "${host_port}" || -z "${cont_port}" ]] && continue
        echo "${stack_name}_${svc}|Stack|${stack_name}|*|${host_port}|${cont_port}|${proto}"
      done <<< "${ports_raw}"
    done
    echo ""

    echo "[images]"
    for svc in "${services[@]}"; do
      echo "${svc}=${svc_image[${svc}]}"
    done
  } > "${state_file}"

  ok "  Build state written."
  echo ""
  ok "  Build phase complete — ready to deploy."
  echo ""
  return 0
}

# ── Helper: read a section from state file ───────────────────────
_state_section() {
  local file="$1" section="$2"
  [[ -z "${file}" || ! -f "${file}" ]] && return
  awk "/^\[${section}\]/{found=1; next} found && /^\[/{exit} found && /^[^#]/{print}" "${file}"
}

# ── Containers: STACK | NAME | ID | IP | REPLICA | STATUS ────────
# STATE_FILE      — active during deploy/update loop, cleared after
# BUILD_STATE_FILE — persists between Build → Deploy steps
STATE_FILE=""
BUILD_STATE_FILE="/tmp/deploy_build_${STACK_NAME}.state"

_collect_container_rows() {
  local rows=()
  local live_svcs=()   # track which services have live data

  # ── Live swarm data (always queried first) ─────────────────────
  local stacks
  stacks=$(docker stack ls --format "{{.Name}}" 2>/dev/null || true)

  for stack in ${stacks}; do
    while IFS='|' read -r svc_name replicas image ports; do
      [[ -z "${svc_name}" ]] && continue
      live_svcs+=("${svc_name}")

      local task_output
      task_output=$(docker service ps "${svc_name}" \
        --no-trunc \
        --format "{{.ID}}|{{.CurrentState}}|{{.DesiredState}}|{{.Name}}" \
        2>/dev/null | grep -v "Shutdown\|shutdown\|Failed\|failed\|Rejected\|rejected" \
        | head -1 || true)

      if [[ -z "${task_output}" ]]; then
        rows+=("${stack}|${svc_name}|—|—|${replicas}|Pending")
        continue
      fi

      while IFS='|' read -r task_id task_state task_desired task_name; do
        [[ -z "${task_id}" ]] && continue
        local state_clean
        state_clean=$(printf '%s' "${task_state}" | awk '{print $1}')

        local container_id container_name container_ip
        container_id=$(docker ps -q --filter "name=${svc_name}" 2>/dev/null | head -1 || true)

        if [[ -n "${container_id}" ]]; then
          container_name=$(docker inspect "${container_id}" \
            --format '{{.Name}}' 2>/dev/null | sed 's|^/||' || echo "${svc_name}")
          container_ip=$(docker inspect "${container_id}" \
            --format '{{range $k,$v := .NetworkSettings.Networks}}{{if $v.IPAddress}}{{$v.IPAddress}},{{end}}{{end}}' \
            2>/dev/null | sed 's/,$//' || echo "—")
          [[ -z "${container_ip}" ]] && container_ip="—"
          container_id="${container_id:0:12}"
        else
          container_name="${svc_name}"
          container_id="—"
          container_ip="—"
        fi

        rows+=("${stack}|${container_name:0:32}|${container_id}|${container_ip:0:18}|${replicas}|${state_clean}")
      done <<< "${task_output}"

    done < <(docker stack services "${stack}" \
      --format "{{.Name}}|{{.Replicas}}|{{.Image}}|{{.Ports}}" 2>/dev/null || true)
  done

  # ── Standalone / Compose containers ───────────────────────────
  while IFS='|' read -r cid cname cstatus; do
    [[ -z "${cid}" ]] && continue
    local is_swarm
    is_swarm=$(docker inspect "${cid}" \
      --format '{{index .Config.Labels "com.docker.swarm.service.id"}}' \
      2>/dev/null || echo "")
    [[ -n "${is_swarm}" ]] && continue
    local compose_proj cip
    compose_proj=$(docker inspect "${cid}" \
      --format '{{index .Config.Labels "com.docker.compose.project"}}' \
      2>/dev/null || echo "")
    local proj="${compose_proj:-standalone}"
    cip=$(docker inspect "${cid}" \
      --format '{{range $k,$v := .NetworkSettings.Networks}}{{if $v.IPAddress}}{{$v.IPAddress}},{{end}}{{end}}' \
      2>/dev/null | sed 's/,$//' || echo "—")
    [[ -z "${cip}" ]] && cip="—"
    rows+=("${proj}|${cname:0:32}|${cid:0:12}|${cip:0:18}|1/1|${cstatus}")
  done < <(docker ps -a --format "{{.ID}}|{{.Names}}|{{.Status}}" 2>/dev/null || true)

  # ── Merge: add Scheduled rows from state file for svcs not yet live
  if [[ -n "${STATE_FILE}" && -f "${STATE_FILE}" ]]; then
    while IFS= read -r state_row; do
      [[ -z "${state_row}" ]] && continue
      # state row: stack|svc_name|—|—|0/N|Scheduled
      local state_svc
      state_svc=$(echo "${state_row}" | cut -d'|' -f2)
      # Only add if not already in live data
      local found=0
      for ls in "${live_svcs[@]:-}"; do
        [[ "${ls}" == "${state_svc}" ]] && { found=1; break; }
      done
      [[ ${found} -eq 0 ]] && rows+=("${state_row}")
    done < <(_state_section "${STATE_FILE}" "containers")
  fi

  for r in "${rows[@]}"; do echo "${r}"; done
}

# ── Table 2: Network & Ports (merged) ────────────────────────────
# NETWORK / SERVICE | KIND | SCOPE / PROJ | SUBNET / HOST:PORT→CONT | PROTO
_collect_connectivity_rows() {
  local rows=()
  local live_nets=()
  local live_svcs=()

  # ── Networks ──────────────────────────────────────────────────
  while IFS='|' read -r net_id net_name driver scope; do
    [[ -z "${net_name}" ]] && continue
    live_nets+=("${net_name}")
    local subnet
    subnet=$(docker network inspect "${net_name}" \
      --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null || echo "—")
    [[ -z "${subnet}" ]] && subnet="—"
    # NAME | KIND | SCOPE | SUBNET/MAPPING | PROTO
    rows+=("${net_name}|${driver}|${scope}|${subnet}|—")
  done < <(docker network ls \
    --format "{{.ID}}|{{.Name}}|{{.Driver}}|{{.Scope}}" 2>/dev/null \
    | grep -vE "^[^|]+\|bridge\|bridge\|local$" \
    | grep -vE "\|host\||\|none\|" \
    | head -10 || true)

  # Planned networks from state file not yet live
  if [[ -n "${STATE_FILE}" && -f "${STATE_FILE}" ]]; then
    while IFS= read -r state_row; do
      [[ -z "${state_row}" ]] && continue
      # state row: net_name|overlay|swarm|—|0  →  reformat to 5-col
      local sn sd ss sm; IFS='|' read -r sn sd ss sm _ <<< "${state_row}"
      local found=0
      for ln in "${live_nets[@]:-}"; do [[ "${ln}" == "${sn}" ]] && { found=1; break; }; done
      [[ ${found} -eq 0 ]] && rows+=("${sn}|${sd}|${ss}|${sm}|—")
    done < <(_state_section "${STATE_FILE}" "networks")
  fi

  # ── Exposed ports ─────────────────────────────────────────────
  local stacks
  stacks=$(docker stack ls --format "{{.Name}}" 2>/dev/null || true)
  for stack in ${stacks}; do
    while IFS='|' read -r svc_name replicas image ports; do
      [[ -z "${svc_name}" ]] && continue
      live_svcs+=("${svc_name}")
      [[ -z "${ports}" || "${ports}" == "—" ]] && continue

      # Swarm can return two formats:
      #   arrow format:    *:3001->3001/tcp,*:80->80/tcp
      #   longform format: published=3001,target=3001,protocol=tcp,mode=ingress
      # Normalise longform → arrow first
      local ports_norm="${ports}"
      if [[ "${ports}" == *"published="* ]]; then
        ports_norm=""
        local IFS_SAVE="${IFS}"; IFS=','
        local chunks=()
        read -ra chunks <<< "${ports}"
        IFS="${IFS_SAVE}"
        local pub="" tgt="" proto="tcp"
        for chunk in "${chunks[@]}"; do
          chunk="${chunk// /}"
          case "${chunk}" in
            published=*) pub="${chunk#published=}" ;;
            target=*)    tgt="${chunk#target=}"    ;;
            protocol=*)  proto="${chunk#protocol=}" ;;
          esac
          # flush when we have pub+tgt
          if [[ -n "${pub}" && -n "${tgt}" ]]; then
            ports_norm+="*:${pub}->${tgt}/${proto},"
            pub=""; tgt=""; proto="tcp"
          fi
        done
        ports_norm="${ports_norm%,}"
      fi

      IFS=',' read -ra port_list <<< "${ports_norm}"
      for p in "${port_list[@]}"; do
        p="${p// /}"
        [[ -z "${p}" || "${p}" != *"->"* ]] && continue
        local proto="tcp"
        [[ "${p}" == *"/udp" ]] && proto="udp"
        p="${p%/*}"
        local host_part="${p%%->*}" cont_port="${p##*->}"
        local host_ip host_port
        if [[ "${host_part}" == *":"* ]]; then
          host_ip="${host_part%%:*}"; host_port="${host_part##*:}"
        else
          host_ip="*"; host_port="${host_part}"
        fi
        [[ -z "${host_port}" || -z "${cont_port}" ]] && continue
        local mapping="${host_ip}:${host_port} → ${cont_port}"
        rows+=("${svc_name:0:28}|Stack|${stack}|${mapping}|${proto}")
      done

      # Fallback: use docker service inspect for port data if above yielded nothing
      if [[ ${#rows[@]} -eq 0 ]] || ! printf '%s\n' "${rows[@]}" | grep -q "^${svc_name:0:28}|Stack"; then
        while IFS= read -r pline; do
          [[ -z "${pline}" ]] && continue
          rows+=("${svc_name:0:28}|Stack|${stack}|${pline}|tcp")
        done < <(docker service inspect "${svc_name}" \
          --format '{{range .Endpoint.Ports}}{{.PublishedPort}}→{{.TargetPort}} {{end}}' \
          2>/dev/null | tr ' ' '\n' | grep -v '^$' || true)
      fi

    done < <(docker stack services "${stack}" \
      --format "{{.Name}}|{{.Replicas}}|{{.Image}}|{{.Ports}}" 2>/dev/null || true)
  done

  # Standalone / compose ports
  while IFS='|' read -r cid cname cports; do
    [[ -z "${cid}" ]] && continue
    local is_swarm
    is_swarm=$(docker inspect "${cid}" \
      --format '{{index .Config.Labels "com.docker.swarm.service.id"}}' \
      2>/dev/null || echo "")
    [[ -n "${is_swarm}" ]] && continue
    [[ -z "${cports}" ]] && continue
    local compose_proj ctype
    compose_proj=$(docker inspect "${cid}" \
      --format '{{index .Config.Labels "com.docker.compose.project"}}' \
      2>/dev/null || echo "")
    [[ -n "${compose_proj}" ]] && ctype="Compose" || ctype="Container"
    local proj="${compose_proj:-standalone}"
    IFS=',' read -ra port_list <<< "${cports}"
    for p in "${port_list[@]}"; do
      p="${p// /}"
      [[ -z "${p}" ]] && continue
      local proto="tcp"
      [[ "${p}" == *"/udp" ]] && proto="udp"
      p="${p%/*}"
      local host_part="${p%%->*}" cont_port="${p##*->}"
      local host_ip host_port
      if [[ "${host_part}" == *":"* ]]; then
        host_ip="${host_part%:*}"; host_port="${host_part##*:}"
      else
        host_ip="*"; host_port="${host_part}"
      fi
      local mapping="${host_ip}:${host_port} → ${cont_port}"
      rows+=("${cname:0:28}|${ctype}|${proj}|${mapping}|${proto}")
    done
  done < <(docker ps --format "{{.ID}}|{{.Names}}|{{.Ports}}" 2>/dev/null || true)

  # Planned ports from state file not yet live
  if [[ -n "${STATE_FILE}" && -f "${STATE_FILE}" ]]; then
    while IFS= read -r state_row; do
      [[ -z "${state_row}" ]] && continue
      # state row: svc|Stack|stack|*|host_port|cont_port|proto
      local ss sk sp shi shp scp spr
      IFS='|' read -r ss sk sp shi shp scp spr <<< "${state_row}"
      local found=0
      for ls in "${live_svcs[@]:-}"; do [[ "${ls}" == "${ss}" ]] && { found=1; break; }; done
      [[ ${found} -eq 0 ]] && rows+=("${ss}|${sk}|${sp}|${shi}:${shp} → ${scp}|${spr}")
    done < <(_state_section "${STATE_FILE}" "ports")
  fi

  for r in "${rows[@]}"; do echo "${r}"; done
}

# ================================================================
#  LIVE SCREEN SYSTEM
#
#  _draw_screen  — every REFRESH_INTERVAL, collects fresh data,
#    renders tables + activity box into a fixed-height buffer,
#    moves cursor up _SCREEN_LINES, erases down, and repaints.
#    First call (_SCREEN_LINES=0) just prints; subsequent calls
#    overwrite in-place — no scroll, no flicker.
# ================================================================

# Fixed row counts per table — keeps screen height constant
_MAX_CONTAINER_ROWS=5
_MAX_CONNECT_ROWS=7
_ACTIVITY_LOG_ROWS=5
_SCREEN_LINES=0

_move_up()    { printf "\033[%dA" "$1"; }
_erase_down() { printf '\033[J';        }

# ── Table definitions (widths + headers) ─────────────────────────
_T1_W="16,32,13,18,7,20"
_T1_H="STACK,CONTAINER NAME,SHORT ID,IP ADDRESS,REPLICA,STATUS"
_T2_W="30,10,16,24,8"
_T2_H="NETWORK / SERVICE,KIND,SCOPE / PROJ,SUBNET / HOST→CONT,PROTO"

_draw_screen() {
  local timestamp="$1"
  local status_label="${2:-Status}"
  local log_file="${3:-}"

  # ── Collect fresh data ────────────────────────────────────────
  local container_rows=()
  while IFS= read -r line; do [[ -n "${line}" ]] && container_rows+=("${line}"); done \
    < <(_collect_container_rows)
  local connect_rows=()
  while IFS= read -r line; do [[ -n "${line}" ]] && connect_rows+=("${line}"); done \
    < <(_collect_connectivity_rows)

  [[ ${#container_rows[@]} -eq 0 ]] && container_rows+=("(none)|(no containers found)|—|—|—|—")
  [[ ${#connect_rows[@]} -eq 0 ]]   && connect_rows+=("(none)|—|—|—|—")

  # ── Write entire frame to a temp file so we can count lines exactly
  local _frame; _frame=$(mktemp /tmp/frame_XXXX.txt)

  {
    print_table_skeleton "[ 1 ]  Containers"       "${_T1_W}" "${_T1_H}"
    print_table_rows     "${_T1_W}" "${_MAX_CONTAINER_ROWS}" "${container_rows[@]}"

    print_table_skeleton "[ 2 ]  Network & Ports"  "${_T2_W}" "${_T2_H}"
    print_table_rows     "${_T2_W}" "${_MAX_CONNECT_ROWS}"   "${connect_rows[@]}"

    # ── Activity box ─────────────────────────────────────────────
    local box_w=76
    printf "\n"
    printf "  \033[36m┌─  Activity Log %s\033[0m\n" "$(printf '%.0s─' {1..62})"
    if [[ -n "${log_file}" && -f "${log_file}" ]]; then
      local total; total=$(wc -l < "${log_file}" 2>/dev/null || echo 0)
      local start=$(( total - _ACTIVITY_LOG_ROWS + 1 ))
      [[ ${start} -lt 1 ]] && start=1
      local shown=0
      while IFS= read -r logline; do
        [[ -z "${logline}" ]] && continue
        printf "  \033[36m│\033[0m %-*s\n" ${box_w} "${logline:0:${box_w}}"
        (( shown++ ))
      done < <(sed -n "${start},${total}p" "${log_file}" 2>/dev/null || true)
      while (( shown < _ACTIVITY_LOG_ROWS )); do
        printf "  \033[36m│\033[0m %-*s\n" ${box_w} ""; (( shown++ ))
      done
    else
      for (( i=0; i<_ACTIVITY_LOG_ROWS; i++ )); do
        printf "  \033[36m│\033[0m %-*s\n" ${box_w} ""
      done
    fi
    printf "  \033[36m├%s┤\033[0m\n"  "$(printf '%.0s─' {1..78})"
    printf "  \033[36m│\033[0m  %-28s \033[1;33m%-*s\033[0m \033[36m│\033[0m\n" \
      "Last refresh: ${timestamp}" $(( box_w - 30 )) "${status_label}"
    printf "  \033[36m└%s┘\033[0m\n"  "$(printf '%.0s─' {1..78})"
    printf "\n"
  } > "${_frame}"

  # Exact line count from file (no subshell string tricks)
  local line_count
  line_count=$(wc -l < "${_frame}")

  # Move up and erase previous frame
  if [[ ${_SCREEN_LINES} -gt 0 ]]; then
    _move_up "${_SCREEN_LINES}"
    _erase_down
  fi

  # Print frame directly — no printf %b re-interpretation
  cat "${_frame}"
  rm -f "${_frame}"

  _SCREEN_LINES=${line_count}
}

# ── Sticky-screen entry: clear + banner + title + skeleton ───────
_print_sticky_header() {
  local title="$1"
  clear
  echo -e "${CYAN}"
  cat <<'BANNER'
  ██╗   ██╗██████╗ ████████╗██╗███╗   ███╗███████╗    ██╗  ██╗██╗   ██╗███╗   ███╗ █████╗
  ██║   ██║██╔══██╗╚══██╔══╝██║████╗ ████║██╔════╝    ██║ ██╔╝██║   ██║████╗ ████║██╔══██╗
  ██║   ██║██████╔╝   ██║   ██║██╔████╔██║█████╗      █████╔╝ ██║   ██║██╔████╔██║███████║
  ██║   ██║██╔═══╝    ██║   ██║██║╚██╔╝██║██╔══╝      ██╔═██╗ ██║   ██║██║╚██╔╝██║██╔══██║
  ╚██████╔╝██║        ██║   ██║██║ ╚═╝ ██║███████╗    ██║  ██╗╚██████╔╝██║ ╚═╝ ██║██║  ██║
   ╚═════╝ ╚═╝        ╚═╝   ╚═╝╚═╝     ╚═╝╚══════╝    ╚═╝  ╚═╝ ╚═════╝ ╚═╝     ╚═╝╚═╝  ╚═╝
BANNER
  echo -e "${RESET}"
  echo -e "  ${BOLD}${BLUE}▶  ${title}${RESET}"
  echo ""
}

# ================================================================
#  BUILD  — pull images, parse compose, write persistent state file
# ================================================================
cmd_build() {
  if [[ ! -f "${COMPOSE_FILE}" ]]; then
    print_banner; err "Compose file not found: ${COMPOSE_FILE}"; pause; return
  fi

  print_banner
  section "Build — Stack: ${STACK_NAME}"
  echo ""
  warn "  Compose : ${COMPOSE_FILE}"
  warn "  Stack   : ${STACK_NAME}"
  warn "  State   : ${BUILD_STATE_FILE}"
  echo ""
  read -rp "  Start build? [Y/n] " go
  [[ "${go,,}" == "n" ]] && { info "Build cancelled."; pause; return; }

  rm -f "${BUILD_STATE_FILE}"

  if ! _build_phase "${COMPOSE_FILE}" "${STACK_NAME}" "${BUILD_STATE_FILE}"; then
    err "Build failed."; rm -f "${BUILD_STATE_FILE}"; pause; return
  fi

  echo ""
  ok "Build complete — state saved to ${BUILD_STATE_FILE}"
  echo -e "  ${DIM}Run option 2 (Deploy) or 3 (Update) to proceed.${RESET}"
  echo ""
  pause
}

# ================================================================
#  DEPLOY
# ================================================================
cmd_deploy() {
  _SCREEN_LINES=0
  STATE_FILE=""

  if ! docker info 2>/dev/null | grep -q "Swarm: active"; then
    print_banner; warn "Docker Swarm not active — initializing…"
    docker swarm init && ok "Swarm initialized"
  fi
  if [[ ! -f "${COMPOSE_FILE}" ]]; then
    print_banner; err "Compose file not found: ${COMPOSE_FILE}"; pause; return
  fi

  print_banner
  section "Deploy — Stack: ${STACK_NAME}"
  echo ""
  warn "  Compose : ${COMPOSE_FILE}"
  warn "  Stack   : ${STACK_NAME}"
  echo ""

  # ── Check for existing build state ───────────────────────────
  if [[ -f "${BUILD_STATE_FILE}" ]]; then
    local built_at
    built_at=$(grep "^built_at=" "${BUILD_STATE_FILE}" 2>/dev/null | cut -d'=' -f2 || echo "unknown")
    ok "  Build state found (built: ${built_at})"
    STATE_FILE="${BUILD_STATE_FILE}"
  else
    warn "  No build state found — tables will populate as containers start."
    warn "  Run option 1 (Build) first for pre-populated tables."
  fi

  echo ""
  read -rp "  Proceed with deploy? [y/N] " confirm
  [[ "${confirm,,}" == "y" ]] || { info "Deploy cancelled."; STATE_FILE=""; pause; return; }

  # ── Switch to sticky live screen ─────────────────────────────
  _print_sticky_header "Deploy — Stack: ${STACK_NAME}"

  local deploy_log; deploy_log=$(mktemp /tmp/deploy_log_XXXX.txt)
  local deploy_pid
  docker stack deploy -c "${COMPOSE_FILE}" "${STACK_NAME}" \
    > "${deploy_log}" 2>&1 &
  deploy_pid=$!

  local elapsed=0 cmd_done=0 si=0
  local spinner=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')

  _cursor_hide
  trap '_cursor_show; rm -f "${deploy_log}"; STATE_FILE=""; trap - INT; return' INT

  while true; do
    # Track when the deploy command itself finishes
    if [[ ${cmd_done} -eq 0 ]] && ! kill -0 "${deploy_pid}" 2>/dev/null; then
      wait "${deploy_pid}" 2>/dev/null || true; cmd_done=1
    fi

    # Count desired vs running replicas across all services in stack
    local desired=0 running=0
    while IFS='/' read -r r d; do
      [[ "${d}" =~ ^[0-9]+$ ]] && (( desired += d )) || true
      [[ "${r}" =~ ^[0-9]+$ ]] && (( running += r )) || true
    done < <(docker stack services "${STACK_NAME}" \
      --format "{{.Replicas}}" 2>/dev/null || true)

    local converged=0
    [[ ${desired} -gt 0 && ${running} -eq ${desired} ]] && converged=1

    local label
    if [[ ${converged} -eq 1 ]]; then
      label="All Running ✔  ${running}/${desired} replicas"
    elif [[ ${cmd_done} -eq 1 ]]; then
      label="Converging ${spinner[$((si % 10))]}  ${running}/${desired} Running  ${elapsed}s"
    else
      label="Deploying  ${spinner[$((si % 10))]}  ${running}/${desired} Running  ${elapsed}s"
    fi

    _draw_screen "$(date '+%Y-%m-%d %H:%M:%S')" "${label}" "${deploy_log}"
    ((si++)); ((elapsed+=REFRESH_INTERVAL)) || true

    # Exit only when all replicas running, or timeout after 5 min
    [[ ${converged} -eq 1 ]] && break
    [[ ${elapsed} -ge 300 ]] && { break; }
    sleep "${REFRESH_INTERVAL}"
  done

  _cursor_show; trap - INT
  rm -f "${deploy_log}" "${BUILD_STATE_FILE}"
  STATE_FILE=""
  echo ""
  ok "Deploy finished — all services running.  Press [Enter] to return to menu."
  pause
}

# ================================================================
#  ROLLING UPDATE
# ================================================================
cmd_update() {
  _SCREEN_LINES=0
  STATE_FILE=""

  if [[ "$(_stack_exists)" != "yes" ]]; then
    print_banner; err "Stack '${STACK_NAME}' not found — deploy first (option 2)"; pause; return
  fi
  if [[ ! -f "${COMPOSE_FILE}" ]]; then
    print_banner; err "Compose file not found: ${COMPOSE_FILE}"; pause; return
  fi

  print_banner
  section "Rolling Update — Stack: ${STACK_NAME}"
  echo ""
  warn "  This will re-deploy stack '${STACK_NAME}' with current ${COMPOSE_FILE}"
  echo ""

  if [[ -f "${BUILD_STATE_FILE}" ]]; then
    local built_at
    built_at=$(grep "^built_at=" "${BUILD_STATE_FILE}" 2>/dev/null | cut -d'=' -f2 || echo "unknown")
    ok "  Build state found (built: ${built_at})"
    STATE_FILE="${BUILD_STATE_FILE}"
  else
    warn "  No build state found — run option 1 (Build) first for best results."
  fi

  echo ""
  read -rp "  Proceed with rolling update? [y/N] " confirm
  [[ "${confirm,,}" == "y" ]] || { info "Update cancelled."; STATE_FILE=""; pause; return; }

  # ── Switch to sticky live screen ─────────────────────────────
  _print_sticky_header "Rolling Update — Stack: ${STACK_NAME}"

  local update_log; update_log=$(mktemp /tmp/update_log_XXXX.txt)
  local update_pid
  docker stack deploy -c "${COMPOSE_FILE}" "${STACK_NAME}" \
    > "${update_log}" 2>&1 &
  update_pid=$!

  local elapsed=0 cmd_done=0 si=0
  local spinner=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')

  _cursor_hide
  trap '_cursor_show; rm -f "${update_log}" "${BUILD_STATE_FILE}"; STATE_FILE=""; trap - INT; return' INT

  while true; do
    if [[ ${cmd_done} -eq 0 ]] && ! kill -0 "${update_pid}" 2>/dev/null; then
      wait "${update_pid}" 2>/dev/null || true; cmd_done=1
    fi

    local desired=0 running=0
    while IFS='/' read -r r d; do
      [[ "${d}" =~ ^[0-9]+$ ]] && (( desired += d )) || true
      [[ "${r}" =~ ^[0-9]+$ ]] && (( running += r )) || true
    done < <(docker stack services "${STACK_NAME}" \
      --format "{{.Replicas}}" 2>/dev/null || true)

    local converged=0
    [[ ${desired} -gt 0 && ${running} -eq ${desired} ]] && converged=1

    local label
    if [[ ${converged} -eq 1 ]]; then
      label="All Running ✔  ${running}/${desired} replicas"
    elif [[ ${cmd_done} -eq 1 ]]; then
      label="Converging ${spinner[$((si % 10))]}  ${running}/${desired} Running  ${elapsed}s"
    else
      label="Updating   ${spinner[$((si % 10))]}  ${running}/${desired} Running  ${elapsed}s"
    fi

    _draw_screen "$(date '+%Y-%m-%d %H:%M:%S')" "${label}" "${update_log}"
    ((si++)); ((elapsed+=REFRESH_INTERVAL)) || true
    [[ ${converged} -eq 1 ]] && break
    [[ ${elapsed} -ge 300 ]] && break
    sleep "${REFRESH_INTERVAL}"
  done

  _cursor_show; trap - INT
  rm -f "${update_log}" "${BUILD_STATE_FILE}"
  STATE_FILE=""
  echo ""
  ok "Update finished — all services running.  Press [Enter] to return to menu."
  pause
}

# ================================================================
#  LIVE MONITOR  (real-time cluster view, Ctrl+C to exit)
# ================================================================
cmd_monitor() {
  _SCREEN_LINES=0
  _print_sticky_header "Live Monitor — Full Cluster"
  echo -e "  \033[2mRefreshes every ${REFRESH_INTERVAL}s  —  Ctrl+C to return to menu\033[0m"
  echo ""

  _cursor_hide
  trap '_cursor_show; echo ""; trap - INT; _SCREEN_LINES=0; return' INT

  while true; do
    _draw_screen "$(date '+%Y-%m-%d %H:%M:%S')" "Live Monitor" ""
    sleep "${REFRESH_INTERVAL}"
  done
}

# ================================================================
#  DESTROY — list all stacks, confirm each y/n before removing
# ================================================================
cmd_destroy() {
  _SCREEN_LINES=0
  print_banner
  section "Destroy — Remove Stacks"
  echo ""

  # ── Discover all deployed stacks ─────────────────────────────
  local all_stacks=()
  while IFS= read -r s; do [[ -n "${s}" ]] && all_stacks+=("${s}"); done \
    < <(docker stack ls --format "{{.Name}}" 2>/dev/null || true)

  if [[ ${#all_stacks[@]} -eq 0 ]]; then
    warn "No stacks currently deployed."
    pause; return
  fi

  # ── Print numbered list ───────────────────────────────────────
  err "WARNING: Removing a stack permanently removes all its services."
  err "         Volumes with persistent data will NOT be auto-removed."
  echo ""
  echo -e "  ${BOLD}${WHITE}Deployed stacks:${RESET}"
  echo ""
  local idx=1
  for s in "${all_stacks[@]}"; do
    local svc_count
    svc_count=$(docker stack services "${s}" 2>/dev/null | tail -n +2 | wc -l | tr -d ' ')
    printf "  %b[%d]%b  %-24s %b%s service(s)%b\n" \
      "${CYAN}" "${idx}" "${RESET}" "${s}" "${DIM}" "${svc_count}" "${RESET}"
    ((idx++))
  done
  echo ""
  echo -e "  ${DIM}Enter numbers (e.g. 1 3), stack names, 'all', or blank to cancel.${RESET}"
  echo ""
  read -rp "  Select stacks to destroy: " selection
  [[ -z "${selection}" ]] && { info "Cancelled — nothing removed."; pause; return; }

  # ── Resolve selection to a list of stack names ───────────────
  local to_remove=()
  if [[ "${selection,,}" == "all" ]]; then
    to_remove=("${all_stacks[@]}")
  else
    for token in ${selection}; do
      if [[ "${token}" =~ ^[0-9]+$ ]]; then
        local i=$(( token - 1 ))
        if [[ ${i} -ge 0 && ${i} -lt ${#all_stacks[@]} ]]; then
          to_remove+=("${all_stacks[$i]}")
        else
          warn "No stack at index ${token} — skipped."
        fi
      else
        # Treat as stack name
        local found=0
        for s in "${all_stacks[@]}"; do
          [[ "${s}" == "${token}" ]] && { to_remove+=("${s}"); found=1; break; }
        done
        [[ ${found} -eq 0 ]] && warn "Stack '${token}' not found — skipped."
      fi
    done
  fi

  [[ ${#to_remove[@]} -eq 0 ]] && { warn "Nothing to remove."; pause; return; }

  # ── Confirm each stack individually ──────────────────────────
  echo ""
  local confirmed=()
  for s in "${to_remove[@]}"; do
    read -rp "  Remove stack '${s}'? [y/N] " yn
    [[ "${yn,,}" == "y" ]] && confirmed+=("${s}") || info "Skipped '${s}'."
  done

  [[ ${#confirmed[@]} -eq 0 ]] && { info "Nothing confirmed — cancelled."; pause; return; }

  # ── Remove confirmed stacks ───────────────────────────────────
  echo ""
  local spinner=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
  for s in "${confirmed[@]}"; do
    echo ""
    if docker stack rm "${s}" 2>/dev/null; then
      ok "Stack '${s}' removal issued"
      local elapsed=0 si=0
      _cursor_hide
      while docker stack ps "${s}" &>/dev/null 2>&1; do
        printf "\r  \033[36m%s\033[0m  Waiting for '%s' tasks to stop… (%ds)" \
          "${spinner[$((si % 10))]}" "${s}" "${elapsed}"
        ((si++)); sleep 2; ((elapsed+=2)) || true
        [[ ${elapsed} -ge 90 ]] && break
      done
      _cursor_show
      printf "\r%70s\r" ""
      ok "Stack '${s}' removed"
    else
      err "Failed to remove stack '${s}'"
    fi
  done

  echo ""
  ok "Destroy complete.  Press [Enter] to return to menu."
  pause
}

# ================================================================
#  MAIN MENU
# ================================================================
main_menu() {
  if ! docker info 2>/dev/null | grep -q "Swarm: active"; then
    docker swarm init &>/dev/null || true
  fi

  while true; do
    print_banner

    local swarm_state; swarm_state="$(_swarm_active)"
    local stack_label
    if [[ "$(_stack_exists)" == "yes" ]]; then
      local svc_count
      svc_count=$(docker stack services "${STACK_NAME}" 2>/dev/null \
        | tail -n +2 | wc -l | tr -d ' ')
      stack_label="${GREEN}Deployed — ${svc_count} service(s)${RESET}"
    else
      stack_label="${YELLOW}Not deployed${RESET}"
    fi

    local node_count
    node_count=$(docker node ls 2>/dev/null | tail -n +2 | wc -l | tr -d ' ' || echo "0")

    # Build state indicator
    local build_label
    if [[ -f "${BUILD_STATE_FILE}" ]]; then
      local built_at; built_at=$(grep "^built_at=" "${BUILD_STATE_FILE}" 2>/dev/null | cut -d'=' -f2 || echo "?")
      build_label="${GREEN}Ready  (${built_at})${RESET}"
    else
      build_label="${YELLOW}Not built${RESET}"
    fi

    echo -e "  ${BOLD}${WHITE}MAIN MENU${RESET}"
    echo ""
    printf "  %b%s%b\n" "${CYAN}" \
      "${TL}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${TR}" \
      "${RESET}"
    echo -e "  ${V}  ${CYAN}1${RESET}  ${v}  ${WHITE}Build           ${DIM}Pull images, validate, write state file${RESET}    ${V}"
    echo -e "  ${V}  ${CYAN}2${RESET}  ${v}  ${WHITE}Deploy          ${DIM}Deploy stack (uses build state if ready)${RESET}   ${V}"
    echo -e "  ${V}  ${CYAN}3${RESET}  ${v}  ${WHITE}Rolling Update  ${DIM}Re-deploy with latest config/image${RESET}        ${V}"
    echo -e "  ${V}  ${CYAN}4${RESET}  ${v}  ${WHITE}Live Monitor    ${DIM}Real-time cluster view — Ctrl+C to exit${RESET}   ${V}"
    echo -e "  ${V}  ${CYAN}5${RESET}  ${v}  ${WHITE}Destroy         ${DIM}Remove stack services  ${RED}⚠ danger${RESET}            ${V}"
    echo -e "  ${V}  ${RED}0${RESET}  ${v}  ${WHITE}Exit${RESET}                                                   ${V}"
    printf "  %b%s%b\n" "${CYAN}" \
      "${BL}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${BR}" \
      "${RESET}"
    echo ""
    echo -e "  ${DIM}Stack: ${BOLD}${WHITE}${STACK_NAME}${RESET}${DIM}  │  Swarm: ${swarm_state}  │  Nodes: ${node_count}  │  Stack: ${RESET}${stack_label}${DIM}  │  Build: ${RESET}${build_label}"
    echo ""
    read -rp "  Select option [0-5]: " choice

    case "${choice}" in
      1) cmd_build   ;;
      2) cmd_deploy  ;;
      3) cmd_update  ;;
      4) cmd_monitor ;;
      5) cmd_destroy ;;
      0) echo ""; echo -e "  ${GREEN}Goodbye!${RESET}"; echo ""; exit 0 ;;
      *) warn "Invalid — choose 0–5"; sleep 1 ;;
    esac
  done
}

# ── Entry ────────────────────────────────────────────────────────
main_menu