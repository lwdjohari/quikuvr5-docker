#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# Quikuvr5 - Docker UVR5 Quikseries - Container Entrypoint
# ============================================================

UVR_HOME="/opt/UVR5-UI"
UVR_ENV="${UVR_HOME}/env"
UVR_PY="${UVR_ENV}/bin/python"
UVR_AUDIO_SEPARATOR="${UVR_ENV}/bin/audio-separator"
PORT="${UVR_PORT:-7860}"

# Gradio binds to 127.0.0.1 by default — unreachable from host via Docker port mapping.
# Override to 0.0.0.0 so the UI is accessible. Compose also sets this, but this
# fallback covers `docker run` without compose.
export GRADIO_SERVER_NAME="${GRADIO_SERVER_NAME:-0.0.0.0}"

# Symlinked dirs resolve to /data/* which Gradio rejects as outside the working
# directory.  GRADIO_ALLOWED_PATHS whitelists the real targets so the UI can
# serve output files, cached assets, and model previews.
export GRADIO_ALLOWED_PATHS="${GRADIO_ALLOWED_PATHS:-/data/outputs,/data/inputs,/data/models,/data/cache,/tmp}"

# -------- LOGGING HELPERS --------
log()  { printf '[INFO]  %s\n' "$*"; }
warn() { printf '[WARN]  %s\n' "$*" >&2; }
fail() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

print_hint() {
  printf '\nSuggested troubleshooting:\n' >&2
  printf '  - inspect build log for pip/install failures\n' >&2
  printf '  - verify repo files exist under %s\n' "${UVR_HOME}" >&2
  printf '  - verify env exists under %s\n' "${UVR_ENV}" >&2
  printf '  - verify host mounts are writable by UID:GID %s:%s\n' "$(id -u)" "$(id -g)" >&2
  printf '  - if GPU enabled, verify NVIDIA Container Toolkit is installed\n\n' >&2
}

trap 'rc=$?; warn "Entrypoint failed with exit code ${rc}"; print_hint; exit ${rc}' ERR

echo "============================================================"
echo " Quikuvr5 - Docker UVR5 Quikseries - Container Runtime"
echo "============================================================"
echo "Linggawasistha Djohari. Bad Harmony, 2026."
echo

# -------- ENSURE WORKDIR --------
cd "${UVR_HOME}" || fail "Cannot cd to ${UVR_HOME}"

# -------- FILESYSTEM / INSTALL VALIDATION --------
[ -d "${UVR_HOME}" ]   || fail "UVR_HOME missing: ${UVR_HOME}"
[ -d "${UVR_ENV}" ]    || fail "UVR local env missing: ${UVR_ENV}"
[ -x "${UVR_PY}" ]     || fail "Python missing or not executable: ${UVR_PY}"
[ -x "${UVR_AUDIO_SEPARATOR}" ] || fail "audio-separator missing: ${UVR_AUDIO_SEPARATOR}"

for f in \
  "${UVR_HOME}/app.py" \
  "${UVR_HOME}/requirements.txt" \
  "${UVR_HOME}/assets/config.json" \
  "${UVR_HOME}/assets/models.json" \
  "${UVR_HOME}/assets/default_settings.json"
do
  [ -f "${f}" ] || fail "Required UVR file missing: ${f}"
done

# -------- RUNTIME IMPORT VALIDATION (skippable) --------
if [ "${SKIP_RUNTIME_VALIDATION:-false}" = "true" ]; then
  log "Skipping runtime import validation (SKIP_RUNTIME_VALIDATION=true)"
else
  log "Validating UVR runtime imports (set SKIP_RUNTIME_VALIDATION=true to skip)"
  "${UVR_PY}" -c "
import importlib, sys
mods = [
    'gradio',
    'torch',
    'yt_dlp',
    'audio_separator.separator',
    'assets.themes.loadThemes',
    'assets.i18n.i18n',
]
failed = []
for m in mods:
    try:
        importlib.import_module(m)
    except Exception as e:
        failed.append(f'  {m}: {e}')
if failed:
    print('Runtime import validation FAILED:', file=sys.stderr)
    print(chr(10).join(failed), file=sys.stderr)
    sys.exit(1)
print('Runtime import validation passed')
"
fi

# -------- STORAGE VALIDATION --------
for d in /data/models /data/inputs /data/outputs /data/cache /data/config /data/pip-cache; do
  if [ ! -d "${d}" ]; then
    warn "Missing runtime dir, creating: ${d}"
    mkdir -p "${d}" 2>/dev/null || warn "Cannot create ${d} (read-only mount?)"
  fi
  if [ -d "${d}" ] && [ ! -w "${d}" ]; then
    warn "Runtime dir not writable: ${d}"
  fi
done

# -------- PERSISTENT CONFIG --------
# Persist config.json and default_settings.json to /data/config so theme,
# language, and model settings survive container recreation (stop → start).
CONFIG_DIR="/data/config"
ASSETS_DIR="${UVR_HOME}/assets"

for cfg in config.json default_settings.json; do
  src="${ASSETS_DIR}/${cfg}"
  dst="${CONFIG_DIR}/${cfg}"

  # First run: copy image defaults to the persistent volume
  if [ ! -f "${dst}" ] && [ -f "${src}" ]; then
    cp "${src}" "${dst}"
    log "Copied default ${cfg} to persistent config volume"
  fi

  # Replace the in-container file with a symlink to the persistent copy
  if [ -f "${dst}" ]; then
    rm -f "${src}"
    ln -s "${dst}" "${src}"
    log "Linked ${cfg} → ${dst}"
  fi
done

# -------- PERSISTENT MODELS --------
# UVR5 app.py uses models_dir="./models" (relative to /opt/UVR5-UI/).
# Replace /opt/UVR5-UI/models/ with a symlink to /data/models/ so downloaded
# model weights are stored on the host volume and survive container recreation.
APP_MODELS="${UVR_HOME}/models"
if [ -d "/data/models" ] && [ -w "/data/models" ]; then
  if [ -d "${APP_MODELS}" ] && [ ! -L "${APP_MODELS}" ]; then
    find "${APP_MODELS}" -type f ! -name ".gitkeep" -exec cp -n {} /data/models/ \; 2>/dev/null || true
    rm -rf "${APP_MODELS}"
  fi
  if [ ! -L "${APP_MODELS}" ]; then
    ln -s /data/models "${APP_MODELS}"
    log "Linked ./models → /data/models"
  fi
fi

# -------- PERSISTENT OUTPUTS --------
# UVR5 app.py uses out_dir="./outputs" (relative to /opt/UVR5-UI/).
# Symlink to /data/outputs so separated audio is written to the host volume.
APP_OUTPUTS="${UVR_HOME}/outputs"
if [ -d "/data/outputs" ] && [ -w "/data/outputs" ]; then
  if [ -d "${APP_OUTPUTS}" ] && [ ! -L "${APP_OUTPUTS}" ]; then
    find "${APP_OUTPUTS}" -type f -exec cp -n {} /data/outputs/ \; 2>/dev/null || true
    rm -rf "${APP_OUTPUTS}"
  fi
  if [ ! -L "${APP_OUTPUTS}" ]; then
    ln -s /data/outputs "${APP_OUTPUTS}"
    log "Linked ./outputs → /data/outputs"
  fi
fi

# -------- PERSISTENT YOUTUBE DOWNLOADS --------
# UVR5 app.py downloads YouTube audio to ./ytdl/ (relative to /opt/UVR5-UI/).
# Symlink to /data/inputs/ytdl so downloads land on the host volume.
APP_YTDL="${UVR_HOME}/ytdl"
if [ -d "/data/inputs" ] && [ -w "/data/inputs" ]; then
  mkdir -p /data/inputs/ytdl 2>/dev/null || true
  if [ -d "${APP_YTDL}" ] && [ ! -L "${APP_YTDL}" ]; then
    find "${APP_YTDL}" -type f -exec cp -n {} /data/inputs/ytdl/ \; 2>/dev/null || true
    rm -rf "${APP_YTDL}"
  fi
  if [ ! -L "${APP_YTDL}" ]; then
    ln -s /data/inputs/ytdl "${APP_YTDL}"
    log "Linked ./ytdl → /data/inputs/ytdl"
  fi
fi

# -------- PERSISTENT HF / TORCH HUB CACHE --------
# Gradio downloads themes (e.g. NoCrypt/miku) to ~/.cache/huggingface/.
# Torch hub may also cache models here. Symlink to /data/cache so these
# survive container recreation and avoid re-downloading on every start.
USER_CACHE="/home/appuser/.cache"
if [ -d "/data/cache" ] && [ -w "/data/cache" ]; then
  # Move any existing cache contents to the persistent volume
  if [ -d "${USER_CACHE}" ] && [ ! -L "${USER_CACHE}" ]; then
    cp -a "${USER_CACHE}/." /data/cache/ 2>/dev/null || true
    rm -rf "${USER_CACHE}"
  fi
  # Create symlink: ~/.cache → /data/cache
  if [ ! -L "${USER_CACHE}" ]; then
    ln -s /data/cache "${USER_CACHE}"
    log "Linked ~/.cache → /data/cache"
  fi
fi

# -------- GPU VALIDATION --------
if command -v nvidia-smi >/dev/null 2>&1; then
  log "GPU runtime detected"
  nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader 2>/dev/null \
    || warn "nvidia-smi present but query failed"
else
  warn "No nvidia-smi detected; UVR will run CPU-only"
fi

# -------- DIAGNOSTICS --------
echo
echo "Runtime diagnostics"
echo "-------------------"
echo "User:             $(id)"
echo "Repo:             ${UVR_HOME}"
echo "Python:           $(${UVR_PY} --version 2>&1)"
echo "Port:             ${PORT}"
echo "audio-separator:  ${UVR_AUDIO_SEPARATOR}"
echo "Models dir:       /data/models"
echo "Inputs dir:       /data/inputs"
echo "Outputs dir:      /data/outputs"
echo "Model file count: $(ls -1 /data/models/ 2>/dev/null | wc -l || echo 0)"
echo

# -------- COMMAND ROUTER --------
cmd="${1:-start}"

case "${cmd}" in
  start)
    log "Starting UVR5 Gradio UI on port ${PORT}"
    exec "${UVR_PY}" app.py --listen-port "${PORT}"
    ;;
  shell)
    exec /bin/bash
    ;;
  info)
    "${UVR_PY}" -c "
import torch
print('Torch:', torch.__version__)
print('CUDA available:', torch.cuda.is_available())
if torch.cuda.is_available():
    print('CUDA device:', torch.cuda.get_device_name(0))
    print('CUDA memory:', round(torch.cuda.get_device_properties(0).total_mem / 1e9, 1), 'GB')
"
    ;;
  validate)
    log "Full validation passed"
    ;;
  *)
    fail "Unknown command: ${cmd}. Valid commands: start, shell, info, validate"
    ;;
esac
