#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
#  Quikuvr5 - Docker UVR5 Quikseries Controller
#  Ultimate Vocal Remover 5 - Production CLI
# ============================================================
#
#  Single entry point for building, running, and managing the
#  UVR5 Docker container. Supports both rootless Docker and
#  sudo-based Docker access.
#
#  Usage:  ./run-quikuvr5.sh <command>
#
#  Commands:
#    preflight   Full host dependency & env audit with fix hints
#    check       Show current configuration
#    build       Build the Docker image
#    validate    Run in-container validation (one-shot)
#    run         Start UVR5 interactively (foreground, --rm)
#    start       Start UVR5 detached (background, restarts)
#    stop        Stop running container
#    restart     Restart container
#    logs        Follow container logs
#    shell       Open bash in running container
#    status      Show container runtime status
#    help        Show this help
#
# ============================================================

readonly SCRIPT_VERSION="1.1.0"

# -------- RESOLVE SCRIPT DIR --------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

# ============================================================
# LOGGING
# ============================================================
_ts()  { date '+%Y-%m-%d %H:%M:%S'; }
log()  { printf '[INFO]  %s  %s\n' "$(_ts)" "$*"; }
warn() { printf '[WARN]  %s  %s\n' "$(_ts)" "$*" >&2; }
fail() { printf '[ERROR] %s  %s\n' "$(_ts)" "$*" >&2; exit 1; }
hint() { printf '        ↳ fix: %s\n' "$*" >&2; }

# ============================================================
# LOAD .env
# ============================================================
ENV_FILE="${SCRIPT_DIR}/.env"
if [ ! -f "${ENV_FILE}" ]; then
  fail ".env not found - run:  cp .env.example .env  then edit it"
fi

set -a
# shellcheck disable=SC1090
source "${ENV_FILE}"
set +a

# ============================================================
# HOST DEPENDENCY CHECKS  (with actionable fix recommendations)
# ============================================================

# Track issues for preflight summary
declare -a PREFLIGHT_WARNINGS=()
declare -a PREFLIGHT_ERRORS=()

check_cmd() {
  local cmd="$1" pkg="${2:-$1}" purpose="${3:-required}" install_hint="${4:-}"
  if command -v "${cmd}" >/dev/null 2>&1; then
    return 0
  fi
  local msg="Missing command: ${cmd} (${purpose})"
  if [ -n "${install_hint}" ]; then
    msg="${msg} - install: ${install_hint}"
  else
    msg="${msg} - install: sudo apt install ${pkg}  OR  sudo dnf install ${pkg}"
  fi
  if [ "${purpose}" = "optional" ]; then
    PREFLIGHT_WARNINGS+=("${msg}")
    return 1
  else
    PREFLIGHT_ERRORS+=("${msg}")
    return 1
  fi
}

check_host_commands() {
  local ok=true

  # Required
  check_cmd "grep"      "grep"       "required" || ok=false
  check_cmd "awk"       "gawk"       "required" || ok=false
  check_cmd "mkdir"     "coreutils"  "required" || ok=false
  check_cmd "id"        "coreutils"  "required" || ok=false
  check_cmd "curl"      "curl"       "required for healthchecks" || ok=false
  check_cmd "git"       "git"        "required for clone operations" || ok=false

  # Docker - special handling
  if ! command -v docker >/dev/null 2>&1; then
    PREFLIGHT_ERRORS+=("Docker not installed - see https://docs.docker.com/engine/install/")
    ok=false
  fi

  # Optional
  check_cmd "jq"        "jq"         "optional" "sudo apt install jq" || true
  check_cmd "nvidia-smi" "nvidia-utils" "optional (GPU mode)" \
    "install NVIDIA driver: https://docs.nvidia.com/datacenter/tesla/tesla-installation-notes/" || true

  ${ok}
}

# ============================================================
# DOCKER ACCESS DETECTION  (rootless / sudo / fail)
# ============================================================
detect_docker() {
  # 1. Direct access (rootless Docker, user in docker group, or running as root)
  if docker info >/dev/null 2>&1; then
    echo "docker"
    return 0
  fi

  # 2. sudo-based access
  if command -v sudo >/dev/null 2>&1; then
    if sudo -n docker info >/dev/null 2>&1; then
      # Non-interactive sudo works (NOPASSWD or cached credentials)
      echo "sudo docker"
      return 0
    fi
    # Interactive sudo - test it, might prompt
    if sudo docker info >/dev/null 2>&1; then
      echo "sudo docker"
      return 0
    fi
  fi

  fail "Docker daemon not accessible.
  Possible fixes:
    1. Add your user to the docker group:  sudo usermod -aG docker \$(whoami) && newgrp docker
    2. Start Docker daemon:                sudo systemctl start docker
    3. Install Docker:                     https://docs.docker.com/engine/install/"
}

DOCKER=""
init_docker() {
  if [ -z "${DOCKER}" ]; then
    DOCKER="$(detect_docker)"
    log "Docker access: ${DOCKER}"
  fi
}

# ============================================================
# ENV VALIDATION  (strict - fail fast on bad config)
# ============================================================
validate_env() {
  local errors=0

  # Required variables
  local required_vars=(
    IMAGE_NAME CONTAINER_NAME UVR_PORT USE_GPU ENABLE_BUILD_TOOLS
    APP_UID APP_GID
    HOST_MODELS HOST_INPUTS HOST_OUTPUTS HOST_CACHE HOST_PIP_CACHE
  )

  for v in "${required_vars[@]}"; do
    if [ -z "${!v:-}" ]; then
      warn ".env variable missing or empty: ${v}"
      hint "Add ${v}=<value> to .env - see .env.example"
      (( errors++ ))
    fi
  done

  # Port range
  if [ -n "${UVR_PORT:-}" ]; then
    if ! [[ "${UVR_PORT}" =~ ^[0-9]+$ ]]; then
      warn "UVR_PORT must be numeric, got: '${UVR_PORT}'"
      hint "Set UVR_PORT to a number between 1024 and 65535"
      (( errors++ ))
    elif (( UVR_PORT < 1 || UVR_PORT > 65535 )); then
      warn "UVR_PORT out of range: ${UVR_PORT}"
      hint "Set UVR_PORT between 1 and 65535 (recommended: 1024+)"
      (( errors++ ))
    fi
  fi

  # Boolean checks
  for bvar in USE_GPU ENABLE_BUILD_TOOLS; do
    local val="${!bvar:-}"
    if [ -n "${val}" ] && [[ "${val}" != "true" && "${val}" != "false" ]]; then
      warn "${bvar} must be 'true' or 'false', got: '${val}'"
      hint "Set ${bvar}=true or ${bvar}=false in .env"
      (( errors++ ))
    fi
  done

  # UID/GID numeric
  for uvar in APP_UID APP_GID; do
    local val="${!uvar:-}"
    if [ -n "${val}" ] && ! [[ "${val}" =~ ^[0-9]+$ ]]; then
      warn "${uvar} must be numeric, got: '${val}'"
      hint "Run 'id -u' and 'id -g' to find correct values"
      (( errors++ ))
    fi
  done

  # Host paths must be absolute
  for pvar in HOST_MODELS HOST_INPUTS HOST_OUTPUTS HOST_CACHE HOST_PIP_CACHE; do
    local val="${!pvar:-}"
    if [ -n "${val}" ] && [[ "${val}" != /* ]]; then
      warn "${pvar} must be an absolute path, got: '${val}'"
      hint "Use full path like /data/uvr5/models - no relative paths or \${VAR} interpolation"
      (( errors++ ))
    fi
  done

  # Git repo URL format
  if [ -n "${UVR5_GIT_REPO:-}" ]; then
    if [[ ! "${UVR5_GIT_REPO}" =~ ^https?://.*\.git$ ]] && [[ ! "${UVR5_GIT_REPO}" =~ ^git@.*\.git$ ]]; then
      warn "UVR5_GIT_REPO doesn't look like a valid git URL: '${UVR5_GIT_REPO}'"
      hint "Use HTTPS (https://github.com/user/repo.git) or SSH (git@github.com:user/repo.git)"
      (( errors++ ))
    fi
  fi

  if (( errors > 0 )); then
    fail "${errors} configuration error(s) found - fix .env and retry"
  fi

  log "Environment validation passed (${#required_vars[@]} variables OK)"
}

# ============================================================
# HOST DIRECTORY PREPARATION
# ============================================================
prepare_dirs() {
  local dir_vars=(HOST_MODELS HOST_INPUTS HOST_OUTPUTS HOST_CACHE HOST_PIP_CACHE)

  for dvar in "${dir_vars[@]}"; do
    local d="${!dvar}"
    if [ ! -d "${d}" ]; then
      log "Creating host directory: ${d}"
      mkdir -p "${d}" 2>/dev/null || {
        warn "Cannot create ${d} as current user"
        hint "Run: sudo mkdir -p ${d} && sudo chown \$(id -u):\$(id -g) ${d}"
        fail "Cannot create host directory: ${d}"
      }
    fi
    if [ ! -w "${d}" ]; then
      warn "Host directory not writable: ${d}"
      hint "Run: sudo chown -R ${APP_UID}:${APP_GID} ${d}"
      fail "Fix directory permissions before proceeding"
    fi
  done

  log "Host directories OK"
}

# ============================================================
# GPU HOST VALIDATION
# ============================================================
validate_gpu_host() {
  if [ "${USE_GPU}" != "true" ]; then
    log "GPU disabled (USE_GPU=${USE_GPU})"
    return 0
  fi

  log "GPU mode enabled - checking host NVIDIA stack"

  # nvidia-smi
  if ! command -v nvidia-smi >/dev/null 2>&1; then
    warn "USE_GPU=true but nvidia-smi not found on host"
    hint "Install NVIDIA driver: https://docs.nvidia.com/datacenter/tesla/tesla-installation-notes/"
    hint "Then install NVIDIA Container Toolkit: https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html"
    warn "Container will likely fail with --gpus all"
    return 1
  fi

  log "nvidia-smi found - querying GPU:"
  nvidia-smi --query-gpu=index,name,driver_version,memory.total,temperature.gpu \
    --format=csv,noheader 2>/dev/null || warn "nvidia-smi query failed"

  # NVIDIA Container Toolkit
  if ! ${DOCKER} info 2>/dev/null | grep -qi "nvidia\|gpu"; then
    if [ ! -e /usr/bin/nvidia-container-runtime ] && [ ! -e /usr/bin/nvidia-container-toolkit ]; then
      warn "NVIDIA Container Toolkit may not be installed"
      hint "Install: https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html"
      hint "Then: sudo nvidia-ctk runtime configure --runtime=docker && sudo systemctl restart docker"
    fi
  fi

  return 0
}

# ============================================================
# GPU FLAGS BUILDER
# ============================================================
build_gpu_flags() {
  local -n _flags=$1
  _flags=()
  if [ "${USE_GPU}" = "true" ]; then
    _flags=(--gpus all)
  fi
}

# ============================================================
# VOLUME ARGS BUILDER
# ============================================================
build_volume_args() {
  local -n _vols=$1
  _vols=(
    -v "${HOST_MODELS}:/data/models"
    -v "${HOST_INPUTS}:/data/inputs"
    -v "${HOST_OUTPUTS}:/data/outputs"
    -v "${HOST_CACHE}:/data/cache"
    -v "${HOST_PIP_CACHE}:/data/pip-cache"
  )
}

# ============================================================
# COMMANDS
# ============================================================

cmd_preflight() {
  echo
  echo "============================================================"
  echo " UVR5 Preflight - Host Dependency & Configuration Audit"
  echo "============================================================"
  echo

  # 1. Host commands
  log "Checking host commands..."
  check_host_commands
  local cmd_ok=$?

  # 2. Docker access
  log "Checking Docker access..."
  init_docker

  # Docker version
  local docker_version
  docker_version="$(${DOCKER} version --format '{{.Server.Version}}' 2>/dev/null || echo "unknown")"
  log "Docker version: ${docker_version}"

  # Docker Compose
  if ${DOCKER} compose version >/dev/null 2>&1; then
    local compose_version
    compose_version="$(${DOCKER} compose version --short 2>/dev/null || echo "unknown")"
    log "Docker Compose version: ${compose_version}"
  else
    PREFLIGHT_WARNINGS+=("Docker Compose v2 not found - 'docker compose' commands won't work")
  fi

  # 3. Env validation
  log "Validating .env configuration..."
  validate_env

  # 4. GPU
  log "Checking GPU stack..."
  validate_gpu_host || true

  # 5. Host directories
  log "Checking host directories..."
  prepare_dirs

  # 6. Disk space
  log "Checking disk space..."
  local data_dir="${HOST_MODELS%/*}"
  if [ -d "${data_dir}" ]; then
    local avail_kb
    avail_kb="$(df -k "${data_dir}" 2>/dev/null | awk 'NR==2{print $4}')"
    if [ -n "${avail_kb}" ]; then
      local avail_gb=$(( avail_kb / 1024 / 1024 ))
      if (( avail_gb < 10 )); then
        PREFLIGHT_WARNINGS+=("Low disk space on ${data_dir}: ~${avail_gb}GB free (recommend 20GB+)")
      else
        log "Disk space on ${data_dir}: ~${avail_gb}GB free"
      fi
    fi
  fi

  # 7. Image check
  log "Checking if image exists..."
  if ${DOCKER} image inspect "${IMAGE_NAME}" >/dev/null 2>&1; then
    local img_size
    img_size="$(${DOCKER} image inspect "${IMAGE_NAME}" --format '{{.Size}}' 2>/dev/null || echo 0)"
    img_size=$(( img_size / 1024 / 1024 ))
    log "Image '${IMAGE_NAME}' found (${img_size}MB)"
  else
    PREFLIGHT_WARNINGS+=("Image '${IMAGE_NAME}' not found - run: ./run-quikuvr5.sh build")
  fi

  # -------- SUMMARY --------
  echo
  echo "============================================================"
  echo " Preflight Summary"
  echo "============================================================"

  if [ ${#PREFLIGHT_WARNINGS[@]} -gt 0 ]; then
    echo
    echo "⚠  WARNINGS (${#PREFLIGHT_WARNINGS[@]}):"
    for w in "${PREFLIGHT_WARNINGS[@]}"; do
      echo "   • ${w}"
    done
  fi

  if [ ${#PREFLIGHT_ERRORS[@]} -gt 0 ]; then
    echo
    echo "✗  ERRORS (${#PREFLIGHT_ERRORS[@]}):"
    for e in "${PREFLIGHT_ERRORS[@]}"; do
      echo "   • ${e}"
    done
    echo
    fail "Preflight failed with ${#PREFLIGHT_ERRORS[@]} error(s) - fix the above and re-run"
  fi

  echo
  echo "✓  All preflight checks passed"
  echo
}

cmd_check() {
  echo
  echo "Quikuvr5 - Docker UVR5 Quikseries - v${SCRIPT_VERSION}"
  echo "============================================="
  echo "Image:         ${IMAGE_NAME}"
  echo "Container:     ${CONTAINER_NAME}"
  echo "Port:          ${UVR_PORT}"
  echo "GPU enabled:   ${USE_GPU}"
  echo "Build tools:   ${ENABLE_BUILD_TOOLS}"
  echo "Git repo:      ${UVR5_GIT_REPO:-https://github.com/Eddycrack864/UVR5-UI.git}"
  echo "Git ref:       ${UVR5_GIT_REF:-latest (unpinned)}"
  echo "App UID:GID:   ${APP_UID}:${APP_GID}"
  echo "Bind address:  ${BIND_ADDRESS:-0.0.0.0}"
  echo "Skip RT check: ${SKIP_RUNTIME_VALIDATION:-false}"
  echo
  echo "Host volumes:"
  echo "  Models:      ${HOST_MODELS}"
  echo "  Inputs:      ${HOST_INPUTS}"
  echo "  Outputs:     ${HOST_OUTPUTS}"
  echo "  Cache:       ${HOST_CACHE}"
  echo "  Pip cache:   ${HOST_PIP_CACHE}"
  echo
}

cmd_build() {
  prepare_dirs

  local -a build_args=(
    --build-arg UID="${APP_UID}"
    --build-arg GID="${APP_GID}"
    --build-arg ENABLE_BUILD_TOOLS="${ENABLE_BUILD_TOOLS}"
  )

  if [ -n "${UVR5_GIT_REPO:-}" ]; then
    log "Using repo: ${UVR5_GIT_REPO}"
    build_args+=(--build-arg GIT_REPO="${UVR5_GIT_REPO}")
  fi

  if [ -n "${UVR5_GIT_REF:-}" ]; then
    log "Pinning to ref: ${UVR5_GIT_REF}"
    build_args+=(--build-arg GIT_REF="${UVR5_GIT_REF}")
  else
    log "Using latest UVR5-UI (no GIT_REF pinned)"
  fi

  log "Building image: ${IMAGE_NAME}"
  ${DOCKER} build \
    "${build_args[@]}" \
    -t "${IMAGE_NAME}" .
  log "Build finished successfully"
}

cmd_validate() {
  prepare_dirs

  local -a gpu_flags=()
  build_gpu_flags gpu_flags

  local -a vol_args=()
  build_volume_args vol_args

  log "Running in-container validation..."
  ${DOCKER} run --rm \
    "${gpu_flags[@]}" \
    -e UVR_PORT="${UVR_PORT}" \
    "${vol_args[@]}" \
    "${IMAGE_NAME}" validate
}

cmd_run() {
  prepare_dirs

  local -a gpu_flags=()
  build_gpu_flags gpu_flags

  local -a vol_args=()
  build_volume_args vol_args

  log "Starting ${CONTAINER_NAME} interactively (port ${UVR_PORT}, Ctrl+C to stop)"
  ${DOCKER} run -it --rm \
    "${gpu_flags[@]}" \
    -e UVR_PORT="${UVR_PORT}" \
    -p "${UVR_PORT}:${UVR_PORT}" \
    "${vol_args[@]}" \
    --name "${CONTAINER_NAME}" \
    "${IMAGE_NAME}" start
}

cmd_start() {
  prepare_dirs

  # Atomic stop + remove (avoids race between stop and rm)
  ${DOCKER} rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true

  local -a gpu_flags=()
  build_gpu_flags gpu_flags

  local -a vol_args=()
  build_volume_args vol_args

  log "Starting ${CONTAINER_NAME} detached (port ${UVR_PORT})"
  ${DOCKER} run -d \
    "${gpu_flags[@]}" \
    -e UVR_PORT="${UVR_PORT}" \
    -p "${UVR_PORT}:${UVR_PORT}" \
    "${vol_args[@]}" \
    --restart unless-stopped \
    --name "${CONTAINER_NAME}" \
    "${IMAGE_NAME}" start

  log "Container started - access UI at http://localhost:${UVR_PORT}"
  log "View logs: ./run-quikuvr5.sh logs"
}

cmd_stop() {
  log "Stopping ${CONTAINER_NAME}..."
  ${DOCKER} stop "${CONTAINER_NAME}" >/dev/null 2>&1 && log "Stopped" || warn "Container not running"
}

cmd_restart() {
  log "Restarting ${CONTAINER_NAME}..."
  ${DOCKER} restart "${CONTAINER_NAME}" >/dev/null 2>&1 && log "Restarted" || {
    warn "Container not running - starting fresh"
    cmd_start
  }
}

cmd_logs() {
  ${DOCKER} logs -f "${CONTAINER_NAME}"
}

cmd_shell() {
  if ! ${DOCKER} ps --format '{{.Names}}' | grep -qx "${CONTAINER_NAME}"; then
    fail "Container '${CONTAINER_NAME}' is not running - start it first"
  fi
  ${DOCKER} exec -it "${CONTAINER_NAME}" /bin/bash
}

cmd_status() {
  echo
  if ${DOCKER} ps --format '{{.Names}}' | grep -qx "${CONTAINER_NAME}"; then
    log "Container '${CONTAINER_NAME}' is RUNNING"
    ${DOCKER} ps --filter "name=^${CONTAINER_NAME}$" --format "table {{.Status}}\t{{.Ports}}\t{{.Size}}"
    echo

    # Health
    local health
    health="$(${DOCKER} inspect --format='{{.State.Health.Status}}' "${CONTAINER_NAME}" 2>/dev/null || echo "none")"
    echo "Health: ${health}"
    echo
  else
    warn "Container '${CONTAINER_NAME}' is NOT running"
    # Check if it exists but stopped
    if ${DOCKER} ps -a --format '{{.Names}}' | grep -qx "${CONTAINER_NAME}"; then
      warn "Container exists but is stopped"
      hint "Run: ./run-quikuvr5.sh start"
    else
      hint "Run: ./run-quikuvr5.sh run  (interactive) or  ./run-quikuvr5.sh start  (detached)"
    fi
  fi
}

cmd_help() {
  echo
  echo "Quikuvr5 - Docker UVR5 Quikseries Controller v${SCRIPT_VERSION}"
  echo "======================================================"
  echo
  echo "Usage:  ./run-quikuvr5.sh <command>"
  echo
  echo "Setup & Diagnostics:"
  echo "  preflight    Full host dependency audit with fix recommendations"
  echo "  check        Show current configuration"
  echo "  status       Show container runtime status"
  echo
  echo "Build & Deploy:"
  echo "  build        Build the Docker image"
  echo "  validate     Run in-container validation (one-shot)"
  echo "  run          Start interactively (foreground, auto-remove)"
  echo "  start        Start detached (background, auto-restart)"
  echo
  echo "Operations:"
  echo "  stop         Stop the running container"
  echo "  restart      Restart the container"
  echo "  logs         Follow container logs"
  echo "  shell        Open bash in running container"
  echo
  echo "  help         Show this help"
  echo
  echo "Docker Compose alternative:"
  echo "  docker compose build"
  echo "  docker compose up -d"
  echo "  docker compose down"
  echo "  docker compose logs -f uvr5"
  echo
  echo "CPU-only deployment:"
  echo "  docker compose -f docker-compose.yml -f docker-compose.cpu.yml up -d"
  echo
}

# ============================================================
# BANNER
# ============================================================

echo "============================================================"
echo " Quikuvr5 - Docker UVR5 Quikseries Controller  v${SCRIPT_VERSION}"
echo " Ultimate Vocal Remover - Production CLI"
echo "============================================================"

# ============================================================
# EARLY VALIDATION (always runs)
# ============================================================
validate_env

# ============================================================
# COMMAND DISPATCH
# ============================================================

# Commands that don't need Docker at all
case "${1:-help}" in
  check)    cmd_check; exit 0 ;;
  help|-h|--help) cmd_help; exit 0 ;;
esac

# All remaining commands need Docker
init_docker

# GPU validation only for commands that use the GPU
case "${1:-}" in
  build|validate|run|start|preflight)
    validate_gpu_host || true
    ;;
esac

case "${1:-help}" in
  preflight)  cmd_preflight ;;
  build)      cmd_build ;;
  validate)   cmd_validate ;;
  run)        cmd_run ;;
  start)      cmd_start ;;
  stop)       cmd_stop ;;
  restart)    cmd_restart ;;
  logs)       cmd_logs ;;
  shell)      cmd_shell ;;
  status)     cmd_status ;;
  *)
    warn "Unknown command: ${1}"
    hint "Run:  ./run-quikuvr5.sh help"
    exit 1
    ;;
esac
