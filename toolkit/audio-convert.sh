#!/usr/bin/env bash
# ============================================================
# audio-convert.sh - Audio Conversion Toolkit
# ============================================================
# Linggawasistha Djohari, Bad Harmony 2026
# A versatile audio conversion script for common formats with configurable encoding profiles.
# Converts between MP4→MP3, MP4→WAV, WAV→MP3, MP3→WAV
# with configurable encoding profiles.
#
# Requires: ffmpeg (with libmp3lame for MP3)
#
# Usage:
#   ./audio-convert.sh [OPTIONS] <input> [input2 ...]
#   ./audio-convert.sh --profile mp3-v0 video.mp4
#   ./audio-convert.sh --profile wav-hq *.mp3
#   ./audio-convert.sh --list-profiles
#   ./audio-convert.sh --batch input_dir/ --profile mp3-320
#
# See profiles.conf for available encoding profiles.
# ============================================================
set -euo pipefail

readonly SCRIPT_VERSION="1.0.0"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROFILES_FILE="${SCRIPT_DIR}/profiles.conf"

# ============================================================
# DEFAULTS
# ============================================================
PROFILE="mp3-v0"
OUTPUT_DIR=""
OVERWRITE=false
DRY_RUN=false
QUIET=false
PARALLEL=1
RECURSIVE=false

# Counters
TOTAL=0
SUCCESS=0
SKIPPED=0
FAILED=0

# ============================================================
# LOGGING
# ============================================================
_ts() { date '+%H:%M:%S'; }

log()  { [[ "${QUIET}" == "true" ]] || echo "[  $(_ts)  ] $*"; }
warn() { echo "[  $(_ts)  ] ⚠ $*" >&2; }
fail() { echo "[  $(_ts)  ] ✖ $*" >&2; exit 1; }
info() { echo "[  $(_ts)  ] ℹ $*"; }
hint() { echo "              ↳ fix: $*" >&2; }

# ============================================================
# PROFILE PARSER
# ============================================================
# Reads INI-style profiles.conf
# Usage: load_profile "mp3-v0"
# Sets: P_FORMAT, P_MODE, P_BITRATE, P_QUALITY, P_SAMPLERATE, P_CHANNELS, P_BIT_DEPTH

load_profile() {
  local name="$1"
  local in_section=false

  # Reset
  P_FORMAT=""
  P_MODE=""
  P_BITRATE=""
  P_QUALITY=""
  P_SAMPLERATE=""
  P_CHANNELS=""
  P_BIT_DEPTH=""

  if [ ! -f "${PROFILES_FILE}" ]; then
    fail "Profiles file not found: ${PROFILES_FILE}"
  fi

  while IFS= read -r line; do
    # Strip comments and whitespace
    line="${line%%#*}"
    line="$(echo "${line}" | xargs 2>/dev/null || true)"
    [ -z "${line}" ] && continue

    # Section header
    if [[ "${line}" =~ ^\[(.+)\]$ ]]; then
      if [ "${BASH_REMATCH[1]}" = "${name}" ]; then
        in_section=true
      else
        # If we were in our section and hit another, we're done
        ${in_section} && break
      fi
      continue
    fi

    # Key=value inside our section
    if ${in_section} && [[ "${line}" =~ ^([a-z_]+)[[:space:]]*=[[:space:]]*(.+)$ ]]; then
      local key="${BASH_REMATCH[1]}"
      local val="${BASH_REMATCH[2]}"
      case "${key}" in
        format)     P_FORMAT="${val}" ;;
        mode)       P_MODE="${val}" ;;
        bitrate)    P_BITRATE="${val}" ;;
        quality)    P_QUALITY="${val}" ;;
        samplerate) P_SAMPLERATE="${val}" ;;
        channels)   P_CHANNELS="${val}" ;;
        bit_depth)  P_BIT_DEPTH="${val}" ;;
        *) warn "Unknown profile key: ${key}" ;;
      esac
    fi
  done < "${PROFILES_FILE}"

  if [ -z "${P_FORMAT}" ]; then
    fail "Profile '${name}' not found in ${PROFILES_FILE}"
  fi

  # Validate
  case "${P_FORMAT}" in
    mp3|wav) ;;
    *) fail "Profile '${name}': unsupported format '${P_FORMAT}' (must be mp3 or wav)" ;;
  esac
}

list_profiles() {
  echo
  echo "Available profiles (from ${PROFILES_FILE}):"
  echo "================================================"
  printf "  %-14s %-6s %-5s %-8s %-6s %-4s %-5s\n" \
    "PROFILE" "FORMAT" "MODE" "BITRATE" "SAMPLE" "CH" "DEPTH"
  echo "  ---------------------------------------------------------"

  local current_name=""
  local fmt="" mode="" br="" qual="" sr="" ch="" bd=""

  while IFS= read -r line; do
    line="${line%%#*}"
    line="$(echo "${line}" | xargs 2>/dev/null || true)"
    [ -z "${line}" ] && continue

    if [[ "${line}" =~ ^\[(.+)\]$ ]]; then
      # Print previous profile
      if [ -n "${current_name}" ]; then
        local rate_display="${br:-}"
        [ -n "${qual}" ] && rate_display="V${qual}"
        printf "  %-14s %-6s %-5s %-8s %-6s %-4s %-5s\n" \
          "${current_name}" "${fmt}" "${mode:--}" "${rate_display:--}" "${sr:--}" "${ch:--}" "${bd:--}"
      fi
      current_name="${BASH_REMATCH[1]}"
      fmt="" mode="" br="" qual="" sr="" ch="" bd=""
      continue
    fi

    if [[ "${line}" =~ ^([a-z_]+)[[:space:]]*=[[:space:]]*(.+)$ ]]; then
      case "${BASH_REMATCH[1]}" in
        format)     fmt="${BASH_REMATCH[2]}" ;;
        mode)       mode="${BASH_REMATCH[2]}" ;;
        bitrate)    br="${BASH_REMATCH[2]}" ;;
        quality)    qual="${BASH_REMATCH[2]}" ;;
        samplerate) sr="${BASH_REMATCH[2]}" ;;
        channels)   ch="${BASH_REMATCH[2]}" ;;
        bit_depth)  bd="${BASH_REMATCH[2]}" ;;
      esac
    fi
  done < "${PROFILES_FILE}"

  # Print last profile
  if [ -n "${current_name}" ]; then
    local rate_display="${br:-}"
    [ -n "${qual}" ] && rate_display="V${qual}"
    printf "  %-14s %-6s %-5s %-8s %-6s %-4s %-5s\n" \
      "${current_name}" "${fmt}" "${mode:--}" "${rate_display:--}" "${sr:--}" "${ch:--}" "${bd:--}"
  fi
  echo
}

# ============================================================
# FFMPEG COMMAND BUILDER
# ============================================================

build_ffmpeg_args() {
  local input="$1"
  local output="$2"

  FFMPEG_ARGS=(-i "${input}" -y -hide_banner -loglevel warning -stats)

  # Sample rate
  [ -n "${P_SAMPLERATE}" ] && FFMPEG_ARGS+=(-ar "${P_SAMPLERATE}")

  # Channels
  [ -n "${P_CHANNELS}" ] && FFMPEG_ARGS+=(-ac "${P_CHANNELS}")

  case "${P_FORMAT}" in
    mp3)
      FFMPEG_ARGS+=(-codec:a libmp3lame)
      if [ "${P_MODE}" = "vbr" ]; then
        FFMPEG_ARGS+=(-q:a "${P_QUALITY:-0}")
      else
        FFMPEG_ARGS+=(-b:a "${P_BITRATE:-320}k")
      fi
      # Strip video stream (for mp4→mp3)
      FFMPEG_ARGS+=(-vn)
      ;;
    wav)
      case "${P_BIT_DEPTH:-16}" in
        16) FFMPEG_ARGS+=(-codec:a pcm_s16le) ;;
        24) FFMPEG_ARGS+=(-codec:a pcm_s24le) ;;
        32) FFMPEG_ARGS+=(-codec:a pcm_f32le) ;;
        *)  fail "Unsupported WAV bit depth: ${P_BIT_DEPTH}" ;;
      esac
      # Strip video stream
      FFMPEG_ARGS+=(-vn)
      ;;
  esac

  FFMPEG_ARGS+=("${output}")
}

# ============================================================
# CONVERSION
# ============================================================

get_output_path() {
  local input="$1"
  local basename
  basename="$(basename "${input}")"
  local name="${basename%.*}"
  local ext="${P_FORMAT}"

  local outdir="${OUTPUT_DIR}"
  if [ -z "${outdir}" ]; then
    outdir="$(dirname "${input}")"
  fi

  echo "${outdir}/${name}.${ext}"
}

convert_file() {
  local input="$1"
  (( TOTAL++ ))

  # Validate input exists
  if [ ! -f "${input}" ]; then
    warn "File not found: ${input}"
    (( FAILED++ ))
    return 1
  fi

  # Validate input format
  local ext="${input##*.}"
  ext="${ext,,}"  # lowercase
  case "${ext}" in
    mp4|m4a|mkv|avi|mov|flv|webm|mp3|wav|flac|ogg|aac|wma) ;;
    *)
      warn "Unsupported input format: .${ext} - ${input}"
      (( FAILED++ ))
      return 1
      ;;
  esac

  # Skip same-format if no re-encoding needed
  if [ "${ext}" = "${P_FORMAT}" ]; then
    warn "Input already .${ext}, will re-encode with profile settings: ${input}"
  fi

  local output
  output="$(get_output_path "${input}")"

  # Skip if exists and not overwriting
  if [ -f "${output}" ] && [ "${OVERWRITE}" = "false" ]; then
    log "SKIP (exists): ${output}"
    (( SKIPPED++ ))
    return 0
  fi

  # Create output directory
  mkdir -p "$(dirname "${output}")"

  # Build ffmpeg command
  build_ffmpeg_args "${input}" "${output}"

  if [ "${DRY_RUN}" = "true" ]; then
    info "DRY RUN: ffmpeg ${FFMPEG_ARGS[*]}"
    (( SUCCESS++ ))
    return 0
  fi

  log "Converting: ${input}"
  log "       → ${output}  [profile: ${PROFILE}]"

  if ffmpeg "${FFMPEG_ARGS[@]}" 2>&1; then
    local size
    size="$(du -h "${output}" 2>/dev/null | cut -f1)"
    log "  ✓ Done (${size})"
    (( SUCCESS++ ))
  else
    warn "  ✖ FAILED: ${input}"
    # Clean up partial output
    rm -f "${output}"
    (( FAILED++ ))
    return 1
  fi
}

# ============================================================
# BATCH PROCESSING
# ============================================================

collect_files() {
  local dir="$1"
  local -a patterns=("*.mp4" "*.m4a" "*.mkv" "*.avi" "*.mov" "*.flv" "*.webm"
                     "*.mp3" "*.wav" "*.flac" "*.ogg" "*.aac" "*.wma"
                     "*.MP4" "*.MP3" "*.WAV" "*.FLAC")

  if [ "${RECURSIVE}" = "true" ]; then
    for pat in "${patterns[@]}"; do
      find "${dir}" -type f -name "${pat}" 2>/dev/null
    done
  else
    for pat in "${patterns[@]}"; do
      # Use nullglob to avoid literal patterns
      local matches
      matches="$(ls -1 "${dir}"/${pat} 2>/dev/null || true)"
      [ -n "${matches}" ] && echo "${matches}"
    done
  fi
}

process_batch() {
  local dir="$1"

  if [ ! -d "${dir}" ]; then
    fail "Batch directory not found: ${dir}"
  fi

  log "Scanning: ${dir} (recursive=${RECURSIVE})"

  local -a files=()
  while IFS= read -r f; do
    [ -n "${f}" ] && files+=("${f}")
  done < <(collect_files "${dir}" | sort -u)

  if [ ${#files[@]} -eq 0 ]; then
    warn "No audio/video files found in: ${dir}"
    return 0
  fi

  log "Found ${#files[@]} file(s) to convert"
  echo

  for f in "${files[@]}"; do
    convert_file "${f}" || true
  done
}

# ============================================================
# HELP
# ============================================================

show_help() {
  cat <<HELP

  audio-convert.sh - Audio Conversion Toolkit v${SCRIPT_VERSION}
  =========================================================
  Linggawasistha Djohari, Bad Harmony 2026

  USAGE:
    ./audio-convert.sh [OPTIONS] <input> [input2 ...]
    ./audio-convert.sh [OPTIONS] --batch <directory>

  CONVERSIONS SUPPORTED:
    MP4/MKV/AVI/MOV/FLV/WEBM → MP3 or WAV  (video → audio)
    WAV/FLAC/OGG/AAC         → MP3          (audio → mp3)
    MP3/FLAC/OGG/AAC         → WAV          (audio → wav)

  OPTIONS:
    -p, --profile <name>    Encoding profile (default: mp3-v0)
    -o, --output <dir>      Output directory (default: same as input)
    -b, --batch <dir>       Batch-convert all files in directory
    -r, --recursive         Include subdirectories in batch mode
    --overwrite             Overwrite existing output files
    --dry-run               Show commands without executing
    --quiet                 Suppress non-error output
    --list-profiles         Show all available profiles
    --profiles-file <path>  Use custom profiles file
    --preflight             Run full dependency & environment audit
    -h, --help              Show this help
    -v, --version           Show version

  EXAMPLES:
    # Convert video to MP3 V0 (default profile)
    ./audio-convert.sh video.mp4

    # Convert to high-quality WAV
    ./audio-convert.sh --profile wav-hq song.mp3

    # Batch convert entire folder to MP3 320
    ./audio-convert.sh --batch ./raw/ --profile mp3-320 --output ./converted/

    # Batch convert recursively, overwriting existing
    ./audio-convert.sh --batch ./music/ -r --overwrite --profile wav-cd

    # Dry run - see what would happen
    ./audio-convert.sh --batch ./files/ --profile mp3-v0 --dry-run

    # Run preflight audit
    ./audio-convert.sh preflight
    ./audio-convert.sh preflight --output /data/uvr5/outputs/

  PROFILES:
    Run  ./audio-convert.sh --list-profiles  to see all options.
    Edit toolkit/profiles.conf to add custom profiles.

HELP
}

# ============================================================
# ARGUMENT PARSER
# ============================================================

parse_args() {
  local -a inputs=()
  local batch_dir=""
  local run_preflight=false

  while [ $# -gt 0 ]; do
    case "$1" in
      -p|--profile)
        [ -n "${2:-}" ] || fail "--profile requires a value"
        PROFILE="$2"; shift 2 ;;
      -o|--output)
        [ -n "${2:-}" ] || fail "--output requires a directory path"
        OUTPUT_DIR="$2"; shift 2 ;;
      -b|--batch)
        [ -n "${2:-}" ] || fail "--batch requires a directory path"
        batch_dir="$2"; shift 2 ;;
      -r|--recursive)
        RECURSIVE=true; shift ;;
      --overwrite)
        OVERWRITE=true; shift ;;
      --dry-run)
        DRY_RUN=true; shift ;;
      --quiet)
        QUIET=true; shift ;;
      --list-profiles)
        list_profiles; exit 0 ;;
      --preflight|preflight)
        run_preflight=true; shift ;;
      --profiles-file)
        [ -n "${2:-}" ] || fail "--profiles-file requires a path"
        # Override the readonly - use a different approach
        PROFILES_FILE_OVERRIDE="$2"; shift 2 ;;
      -h|--help)
        show_help; exit 0 ;;
      -v|--version)
        echo "audio-convert.sh v${SCRIPT_VERSION}"; exit 0 ;;
      -*)
        fail "Unknown option: $1 - run with --help" ;;
      *)
        inputs+=("$1"); shift ;;
    esac
  done

  # Apply profiles file override if set
  if [ -n "${PROFILES_FILE_OVERRIDE:-}" ]; then
    if [ ! -f "${PROFILES_FILE_OVERRIDE}" ]; then
      fail "Custom profiles file not found: ${PROFILES_FILE_OVERRIDE}"
    fi
    # Re-declare (not truly readonly since we need override)
    eval "PROFILES_FILE='${PROFILES_FILE_OVERRIDE}'"
  fi

  # Run preflight if requested (after all flags are parsed)
  if [ "${run_preflight}" = "true" ]; then
    cmd_preflight
    exit $?
  fi

  # Must have either inputs or batch
  if [ -z "${batch_dir}" ] && [ ${#inputs[@]} -eq 0 ]; then
    fail "No input files or --batch directory specified. Run with --help."
  fi

  # Create output dir if specified
  if [ -n "${OUTPUT_DIR}" ]; then
    mkdir -p "${OUTPUT_DIR}" || fail "Cannot create output directory: ${OUTPUT_DIR}"
  fi

  # Preflight
  check_dependencies

  # Load profile
  load_profile "${PROFILE}"
  log "Profile: ${PROFILE} → ${P_FORMAT} (${P_MODE:-pcm})"

  # Execute
  if [ -n "${batch_dir}" ]; then
    process_batch "${batch_dir}"
  else
    for f in "${inputs[@]}"; do
      convert_file "${f}" || true
    done
  fi
}

# ============================================================
# PREFLIGHT & DEPENDENCY AUDIT
# ============================================================

# Quick dependency gate - called before every conversion
check_dependencies() {
  if ! command -v ffmpeg >/dev/null 2>&1; then
    fail "ffmpeg not found. Install it:\n  Ubuntu/Debian:  sudo apt install ffmpeg\n  macOS:          brew install ffmpeg\n  Docker:         Already included in UVR5 image"
  fi
}

# Full preflight audit - called via ./audio-convert.sh preflight
cmd_preflight() {
  echo
  echo "Audio Conversion Toolkit - Preflight Audit"
  echo "============================================"
  echo

  local errors=0
  local warnings=0

  # ---- 1. ffmpeg binary ----
  echo "[1/7] ffmpeg binary"
  if command -v ffmpeg >/dev/null 2>&1; then
    local ffmpeg_path
    ffmpeg_path="$(command -v ffmpeg)"
    echo "  ✓ Found: ${ffmpeg_path}"
  else
    echo "  ✖ NOT FOUND"
    hint "Ubuntu/Debian:  sudo apt install ffmpeg"
    hint "macOS:          brew install ffmpeg"
    hint "Alpine:         apk add ffmpeg"
    hint "Docker UVR5:    Already included in the image"
    (( errors++ ))
  fi

  # ---- 2. ffmpeg version ----
  echo "[2/7] ffmpeg version"
  if command -v ffmpeg >/dev/null 2>&1; then
    local ff_version
    ff_version="$(ffmpeg -version 2>/dev/null | head -1 || echo 'unknown')"
    echo "  ✓ ${ff_version}"

    # Check for minimum version (4.0+)
    local ver_num
    ver_num="$(echo "${ff_version}" | grep -oP 'version \K[0-9]+' || echo '0')"
    if (( ver_num < 4 )); then
      echo "  ⚠ ffmpeg version ${ver_num}.x detected - version 4.0+ recommended"
      hint "Upgrade: sudo apt update && sudo apt install --only-upgrade ffmpeg"
      (( warnings++ ))
    fi
  else
    echo "  - Skipped (ffmpeg not found)"
  fi

  # ---- 3. Audio encoders ----
  echo "[3/7] Audio encoders"
  if command -v ffmpeg >/dev/null 2>&1; then
    local encoders
    encoders="$(ffmpeg -encoders 2>/dev/null || true)"

    local -a required_encoders=(
      "libmp3lame:MP3 encoding (all mp3-* profiles)"
      "pcm_s16le:WAV 16-bit (wav-cd, wav-mono profiles)"
      "pcm_s24le:WAV 24-bit (wav-hq profile)"
      "pcm_f32le:WAV 32-bit float (wav-32 profile)"
    )

    for entry in "${required_encoders[@]}"; do
      local enc="${entry%%:*}"
      local desc="${entry#*:}"
      if echo "${encoders}" | grep -q "${enc}"; then
        echo "  ✓ ${enc} - ${desc}"
      else
        echo "  ✖ ${enc} - ${desc} - MISSING"
        if [ "${enc}" = "libmp3lame" ]; then
          hint "Ubuntu/Debian: sudo apt install ffmpeg   (usually includes lame)"
          hint "macOS:         brew install ffmpeg       (includes lame by default)"
          hint "Manual:        Install LAME and rebuild ffmpeg with --enable-libmp3lame"
          (( errors++ ))
        else
          hint "PCM codecs are built-in - if missing, your ffmpeg build is broken"
          hint "Reinstall: sudo apt install --reinstall ffmpeg"
          (( errors++ ))
        fi
      fi
    done
  else
    echo "  - Skipped (ffmpeg not found)"
  fi

  # ---- 4. Audio decoders ----
  echo "[4/7] Audio decoders"
  if command -v ffmpeg >/dev/null 2>&1; then
    local decoders
    decoders="$(ffmpeg -decoders 2>/dev/null || true)"

    local -a check_decoders=(
      "mp3:MP3 input decoding"
      "pcm_s16le:WAV input decoding"
      "aac:AAC/M4A input decoding"
      "flac:FLAC input decoding"
      "vorbis:OGG Vorbis input decoding"
    )

    for entry in "${check_decoders[@]}"; do
      local dec="${entry%%:*}"
      local desc="${entry#*:}"
      if echo "${decoders}" | grep -q "${dec}"; then
        echo "  ✓ ${dec} - ${desc}"
      else
        echo "  ⚠ ${dec} - ${desc} - not found (some inputs may fail)"
        hint "Reinstall ffmpeg with full codec support"
        (( warnings++ ))
      fi
    done
  else
    echo "  - Skipped (ffmpeg not found)"
  fi

  # ---- 5. Profiles file ----
  echo "[5/7] Profiles configuration"
  if [ -f "${PROFILES_FILE}" ]; then
    local profile_count
    profile_count="$(grep -c '^\[' "${PROFILES_FILE}" 2>/dev/null || echo '0')"
    echo "  ✓ Found: ${PROFILES_FILE}"
    echo "  ✓ Profiles defined: ${profile_count}"

    if [ -r "${PROFILES_FILE}" ]; then
      echo "  ✓ Readable: yes"
    else
      echo "  ✖ Readable: no - permission denied"
      hint "Fix: chmod 644 ${PROFILES_FILE}"
      (( errors++ ))
    fi

    # Validate each profile loads without error
    local -a profile_names=()
    while IFS= read -r pline; do
      if [[ "${pline}" =~ ^\[(.+)\]$ ]]; then
        profile_names+=("${BASH_REMATCH[1]}")
      fi
    done < "${PROFILES_FILE}"

    local bad_profiles=0
    for pn in "${profile_names[@]}"; do
      if ! load_profile "${pn}" 2>/dev/null; then
        echo "  ✖ Profile '${pn}' failed to load"
        hint "Check profiles.conf syntax for [${pn}] section"
        (( bad_profiles++ ))
      fi
    done
    if (( bad_profiles > 0 )); then
      (( errors += bad_profiles ))
    else
      echo "  ✓ All ${#profile_names[@]} profiles validated OK"
    fi
  else
    echo "  ✖ NOT FOUND: ${PROFILES_FILE}"
    hint "The profiles.conf file should be in the same directory as audio-convert.sh"
    hint "Re-clone or copy profiles.conf from the repository"
    (( errors++ ))
  fi

  # ---- 6. Disk space ----
  echo "[6/7] Disk space"
  local check_dir="${OUTPUT_DIR:-$(pwd)}"
  # If the target dir doesn't exist, check the nearest existing parent
  while [ -n "${check_dir}" ] && [ ! -d "${check_dir}" ]; do
    check_dir="$(dirname "${check_dir}")"
  done
  check_dir="${check_dir:-/}"
  if command -v df >/dev/null 2>&1; then
    local avail_kb
    avail_kb="$(df --output=avail "${check_dir}" 2>/dev/null | tail -1 | tr -d ' ' || echo '0')"
    if [ -n "${avail_kb}" ] && [ "${avail_kb}" -gt 0 ] 2>/dev/null; then
      local avail_gb=$(( avail_kb / 1048576 ))
      local avail_mb=$(( avail_kb / 1024 ))
      if (( avail_gb >= 1 )); then
        echo "  ✓ Available: ${avail_gb} GB (at ${check_dir})"
      else
        echo "  ✓ Available: ${avail_mb} MB (at ${check_dir})"
      fi
      if (( avail_mb < 500 )); then
        echo "  ⚠ Less than 500 MB free - large WAV conversions may fail"
        hint "Free up disk space or set --output to a different volume"
        (( warnings++ ))
      fi
    else
      echo "  ⚠ Could not determine free space"
      (( warnings++ ))
    fi
  else
    echo "  ⚠ df not available - cannot check disk space"
    (( warnings++ ))
  fi

  # ---- 7. Output directory ----
  echo "[7/7] Output directory"
  if [ -n "${OUTPUT_DIR}" ]; then
    if [ -d "${OUTPUT_DIR}" ]; then
      echo "  ✓ Exists: ${OUTPUT_DIR}"
      if [ -w "${OUTPUT_DIR}" ]; then
        echo "  ✓ Writable: yes"
      else
        echo "  ✖ Writable: no - permission denied"
        hint "Fix: chmod u+w ${OUTPUT_DIR}"
        hint "Or:  sudo chown \$(id -u):\$(id -g) ${OUTPUT_DIR}"
        (( errors++ ))
      fi
    else
      echo "  ℹ Does not exist yet: ${OUTPUT_DIR} (will be created on conversion)"
      # Check if parent is writable
      local parent
      parent="$(dirname "${OUTPUT_DIR}")"
      if [ -w "${parent}" ]; then
        echo "  ✓ Parent writable: ${parent}"
      else
        echo "  ✖ Parent not writable: ${parent}"
        hint "Fix: sudo mkdir -p ${OUTPUT_DIR} && sudo chown \$(id -u):\$(id -g) ${OUTPUT_DIR}"
        (( errors++ ))
      fi
    fi
  else
    echo "  ℹ No --output set - output goes next to input files"
    echo "  ℹ Make sure input directories are writable"
  fi

  # ---- Summary ----
  echo
  echo "============================================"
  if (( errors > 0 )); then
    echo "✖ Preflight FAILED: ${errors} error(s), ${warnings} warning(s)"
    echo "  Fix the errors above before converting."
    echo "============================================"
    return 1
  elif (( warnings > 0 )); then
    echo "⚠ Preflight passed with ${warnings} warning(s)"
    echo "  Conversions should work but review warnings above."
    echo "============================================"
  else
    echo "✓ All preflight checks passed - ready to convert!"
    echo "============================================"
  fi
  echo
}

# ============================================================
# MAIN
# ============================================================

main() {
  if [ $# -eq 0 ]; then
    show_help
    exit 1
  fi

  echo "============================================================"
  echo " Audio Conversion Toolkit  v${SCRIPT_VERSION}"
  echo "============================================================"

  parse_args "$@"

  # Summary
  echo
  echo "============================================================"
  echo " Conversion Summary"
  echo "============================================================"
  echo "  Total:    ${TOTAL}"
  echo "  Success:  ${SUCCESS}"
  echo "  Skipped:  ${SKIPPED}"
  echo "  Failed:   ${FAILED}"
  echo "============================================================"

  if (( FAILED > 0 )); then
    exit 1
  fi
}

main "$@"
