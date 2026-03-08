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
for d in /data/models /data/inputs /data/outputs /data/cache /data/pip-cache; do
  if [ ! -d "${d}" ]; then
    warn "Missing runtime dir, creating: ${d}"
    mkdir -p "${d}" 2>/dev/null || warn "Cannot create ${d} (read-only mount?)"
  fi
  if [ -d "${d}" ] && [ ! -w "${d}" ]; then
    warn "Runtime dir not writable: ${d}"
  fi
done

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
