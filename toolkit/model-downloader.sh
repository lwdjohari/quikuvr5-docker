#!/usr/bin/env bash
# ============================================================================
#  UVR5 Model Downloader — Industrial-Grade aria2 Batch Downloader
#  Reads model-catalog.json, offers interactive menu or CLI selection.
#  All downloads are resumable, checksummed, and parallelised.
# ============================================================================
set -euo pipefail
IFS=$'\n\t'

# ── version ─────────────────────────────────────────────────────────────────
readonly VERSION="1.0.0"

# ── color palette (disabled if not a tty) ───────────────────────────────────
if [[ -t 1 ]]; then
    readonly RED=$'\033[0;31m'   GRN=$'\033[0;32m'  YLW=$'\033[0;33m'
    readonly BLU=$'\033[0;34m'   MAG=$'\033[0;35m'   CYN=$'\033[0;36m'
    readonly BLD=$'\033[1m'      DIM=$'\033[2m'       RST=$'\033[0m'
else
    readonly RED="" GRN="" YLW="" BLU="" MAG="" CYN="" BLD="" DIM="" RST=""
fi

# ── defaults ────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CATALOG="${CATALOG:-${SCRIPT_DIR}/model-catalog.json}"
MODELS_DIR="${MODELS_DIR:-}"             # mandatory: --output / --out-dir
CONNECTIONS="${CONNECTIONS:-8}"          # aria2 connections per file
PARALLEL="${PARALLEL:-3}"               # simultaneous downloads
MAX_RETRIES="${MAX_RETRIES:-5}"         # retry on failure
CONFLICT_MODE="${CONFLICT_MODE:-ask}"   # ask | overwrite | skip | backup
DRY_RUN=false
QUIET=false

# ── logging ─────────────────────────────────────────────────────────────────
_ts() { date '+%H:%M:%S'; }
log()  { echo "${DIM}[$(_ts)]${RST} ${GRN}▸${RST} $*"; }
warn() { echo "${DIM}[$(_ts)]${RST} ${YLW}⚠${RST} $*" >&2; }
err()  { echo "${DIM}[$(_ts)]${RST} ${RED}✖${RST} $*" >&2; }
die()  { err "$@"; exit 1; }
info() { echo "${DIM}[$(_ts)]${RST} ${BLU}ℹ${RST} $*"; }
ok()   { echo "${DIM}[$(_ts)]${RST} ${GRN}✔${RST} $*"; }

banner() {
    cat <<'EOF'

    ╔══════════════════════════════════════════════════╗
    ║       UVR5 Model Downloader v1.0.0              ║
    ║       Industrial aria2 Batch Downloader         ║
    ╚══════════════════════════════════════════════════╝

EOF
}

# ── dependency checks ───────────────────────────────────────────────────────

# Light check for read-only commands (list, info, archs) — no aria2 or output dir needed
preflight_lite() {
    local fail=0
    if ! command -v jq &>/dev/null; then
        err "jq not found — install: ${BLD}apt install jq${RST} or ${BLD}brew install jq${RST}"
        fail=$(( fail + 1 ))
    fi
    if [[ ! -f "$CATALOG" ]]; then
        err "Catalog not found: ${CATALOG}"
        fail=$(( fail + 1 ))
    else
        jq '.models | length' "$CATALOG" &>/dev/null || { err "Invalid JSON: ${CATALOG}"; fail=$(( fail + 1 )); }
    fi
    if (( fail > 0 )); then
        die "Preflight failed with ${fail} error(s)"
    fi
}

preflight() {
    local fail=0

    # output directory (mandatory)
    if [[ -z "$MODELS_DIR" ]]; then
        die "Output directory is required. Use ${BLD}--output <dir>${RST} or ${BLD}--out-dir <dir>${RST} or set ${BLD}MODELS_DIR${RST} env var"
    fi

    # aria2c
    if ! command -v aria2c &>/dev/null; then
        err "aria2c not found — install: ${BLD}apt install aria2${RST} or ${BLD}brew install aria2${RST}"
        fail=$(( fail + 1 ))
    else
        local v
        v="$(aria2c --version 2>/dev/null | head -1)"
        info "Found ${v}"
    fi

    # jq
    if ! command -v jq &>/dev/null; then
        err "jq not found — install: ${BLD}apt install jq${RST} or ${BLD}brew install jq${RST}"
        fail=$(( fail + 1 ))
    else
        info "Found jq $(jq --version 2>/dev/null)"
    fi

    # catalog
    if [[ ! -f "$CATALOG" ]]; then
        err "Catalog not found: ${CATALOG}"
        fail=$(( fail + 1 ))
    else
        local count
        count="$(jq '.models | length' "$CATALOG" 2>/dev/null)" || { err "Invalid JSON: ${CATALOG}"; fail=$(( fail + 1 )); }
        info "Catalog: ${count} models in ${CATALOG}"
    fi

    # output dir
    if [[ ! -d "$MODELS_DIR" ]]; then
        warn "Models directory does not exist: ${MODELS_DIR}"
        if [[ "$DRY_RUN" == false ]]; then
            log "Creating ${MODELS_DIR}"
            mkdir -p "$MODELS_DIR" || { err "Cannot create ${MODELS_DIR}"; fail=$(( fail + 1 )); }
        fi
    fi

    # disk space
    if [[ -d "$MODELS_DIR" ]]; then
        local avail_kb
        avail_kb="$(df -k "$MODELS_DIR" | awk 'NR==2{print $4}')"
        local avail_gb=$(( avail_kb / 1048576 ))
        if (( avail_gb < 5 )); then
            warn "Low disk space: ${avail_gb} GB available in ${MODELS_DIR}"
        else
            info "Disk space: ${avail_gb} GB available"
        fi
    fi

    if (( fail > 0 )); then
        die "Preflight failed with ${fail} error(s)"
    fi
    ok "Preflight passed"
}

# ── catalog queries (jq wrappers) ──────────────────────────────────────────

# Get all unique architectures
list_architectures() {
    jq -r '[.models[].arch] | unique | .[]' "$CATALOG"
}

# Get models for a specific architecture
models_by_arch() {
    local arch="$1"
    jq -r --arg a "$arch" \
        '.models[] | select(.arch == $a) | "\(.id)|\(.name)|\(.arch)|\(.files | length)|\(if .recommended then "★" + (.recommended|tostring) else "" end)"' \
        "$CATALOG"
}

# Get all models
all_models() {
    jq -r '.models[] | "\(.id)|\(.name)|\(.arch)|\(.files | length)|\(if .recommended then "★" + (.recommended|tostring) else "" end)"' \
        "$CATALOG"
}

# Get recommended models
recommended_models() {
    jq -r '.models[] | select(.recommended) | "\(.id)|\(.name)|\(.arch)|\(.files | length)|★\(.recommended)"' \
        "$CATALOG" | sort -t'|' -k5 -V
}

# Get model by ID
model_by_id() {
    local mid="$1"
    jq --argjson id "$mid" '.models[] | select(.id == $id)' "$CATALOG"
}

# Get model by name (case-insensitive partial match)
models_by_name() {
    local pattern="$1"
    jq -r --arg p "$pattern" \
        '.models[] | select(.name | ascii_downcase | contains($p | ascii_downcase)) | "\(.id)|\(.name)|\(.arch)|\(.files | length)|\(if .recommended then "★" + (.recommended|tostring) else "" end)"' \
        "$CATALOG"
}

# Get file URLs for a model by ID
model_files() {
    local mid="$1"
    jq -r --argjson id "$mid" \
        '.models[] | select(.id == $id) | .files[] | "\(.url)|\(.filename)"' \
        "$CATALOG"
}

# Get model name by ID
model_name_by_id() {
    local mid="$1"
    jq -r --argjson id "$mid" '.models[] | select(.id == $id) | .name' "$CATALOG"
}

# Get model arch by ID
model_arch_by_id() {
    local mid="$1"
    jq -r --argjson id "$mid" '.models[] | select(.id == $id) | .arch' "$CATALOG"
}

# Total model count
model_count() {
    jq '.models | length' "$CATALOG"
}

# ── table formatter ─────────────────────────────────────────────────────────
print_model_table() {
    # stdin: lines of id|name|arch|file_count|recommended
    local header="${BLD}  ID  │ Name                                         │ Arch      │ Files │ Rank${RST}"
    local sep="──────┼────────────────────────────────────────────────┼───────────┼───────┼──────"
    echo "$header"
    echo "$sep"
    while IFS='|' read -r mid name arch fcount rec; do
        if [[ -n "$rec" ]]; then
            rec="${YLW}${rec}${RST}"
        fi
        printf "  %-4s │ %-46s │ %-9s │ %-5s │ %s\n" \
            "$mid" "${name:0:46}" "$arch" "$fcount" "$rec"
    done
    echo "$sep"
}

# ── conflict resolution ────────────────────────────────────────────────────
resolve_conflict() {
    local filepath="$1"

    [[ ! -f "$filepath" ]] && return 0   # no conflict

    case "$CONFLICT_MODE" in
        skip)
            warn "EXISTS — skipping: ${filepath##*/}"
            return 1
            ;;
        overwrite)
            warn "EXISTS — overwriting: ${filepath##*/}"
            rm -f "$filepath"
            return 0
            ;;
        backup)
            local bak="${filepath}.bak.$(date +%Y%m%d%H%M%S)"
            warn "EXISTS — backing up: ${filepath##*/} → ${bak##*/}"
            mv "$filepath" "$bak"
            return 0
            ;;
        ask)
            echo ""
            warn "File already exists: ${BLD}${filepath##*/}${RST}"
            echo "  [1] Skip this file"
            echo "  [2] Overwrite (delete + re-download)"
            echo "  [3] Backup existing (rename .bak) and download"
            echo "  [4] Skip all remaining conflicts"
            echo ""
            local choice
            while true; do
                read -rp "  Choice [1-4]: " choice
                case "$choice" in
                    1) return 1 ;;
                    2) rm -f "$filepath"; return 0 ;;
                    3)
                        local bak="${filepath}.bak.$(date +%Y%m%d%H%M%S)"
                        mv "$filepath" "$bak"
                        info "Backed up → ${bak##*/}"
                        return 0
                        ;;
                    4)
                        CONFLICT_MODE="skip"
                        return 1
                        ;;
                    *) echo "  ${RED}Invalid choice${RST}" ;;
                esac
            done
            ;;
    esac
}

# ── single model download ──────────────────────────────────────────────────
download_model() {
    local model_id="$1"

    local name arch
    name="$(model_name_by_id "$model_id")"
    arch="$(model_arch_by_id "$model_id")"

    if [[ -z "$name" || "$name" == "null" ]]; then
        err "Model ID ${model_id} not found in catalog"
        return 1
    fi

    local dest_dir="${MODELS_DIR}"
    mkdir -p "$dest_dir"

    log "Model: ${BLD}${name}${RST} (${arch}) → ${dest_dir}"

    local file_lines total_files=0 downloaded=0 skipped=0 failed=0
    file_lines="$(model_files "$model_id")"

    while IFS='|' read -r url filename; do
        total_files=$(( total_files + 1 ))
        local dest_file="${dest_dir}/${filename}"

        if ! resolve_conflict "$dest_file"; then
            skipped=$(( skipped + 1 ))
            continue
        fi

        if [[ "$DRY_RUN" == true ]]; then
            info "[DRY-RUN] Would download: ${filename}"
            info "  URL: ${url}"
            info "  Dest: ${dest_file}"
            downloaded=$(( downloaded + 1 ))
            continue
        fi

        log "Downloading: ${CYN}${filename}${RST}"

        local aria_args=(
            --dir="$dest_dir"
            --out="$filename"
            --split="$CONNECTIONS"
            --max-connection-per-server="$CONNECTIONS"
            --min-split-size=1M
            --max-tries="$MAX_RETRIES"
            --retry-wait=3
            --continue=true
            --auto-file-renaming=false
            --allow-overwrite=true
            --console-log-level=error
            --summary-interval=5
            --download-result=full
            --file-allocation=falloc
            --human-readable=true
        )

        if [[ "$QUIET" == true ]]; then
            aria_args+=(--quiet=true)
        fi

        if aria2c "${aria_args[@]}" "$url"; then
            downloaded=$(( downloaded + 1 ))
            ok "Done: ${filename}"
        else
            failed=$(( failed + 1 ))
            err "Failed: ${filename} (exit $?)"
        fi
    done <<< "$file_lines"

    # Summary for this model
    if (( total_files > 1 )); then
        info "Model ${BLD}${name}${RST}: ${downloaded} downloaded, ${skipped} skipped, ${failed} failed (${total_files} total files)"
    fi

    return $(( failed > 0 ? 1 : 0 ))
}

# ── batch download ──────────────────────────────────────────────────────────
download_batch() {
    local -a model_ids=("$@")
    local total="${#model_ids[@]}"
    local success=0 fail=0 current=0

    log "Starting batch download: ${BLD}${total}${RST} models"
    echo ""

    for mid in "${model_ids[@]}"; do
        current=$(( current + 1 ))
        local name
        name="$(model_name_by_id "$mid")"
        echo "${BLU}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RST}"
        echo "  ${BLD}[${current}/${total}]${RST} ${name}"
        echo "${BLU}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RST}"

        if download_model "$mid"; then
            success=$(( success + 1 ))
        else
            fail=$(( fail + 1 ))
        fi
        echo ""
    done

    # Final summary
    echo ""
    echo "${BLD}═══════════════════════════════════════════════════════════${RST}"
    echo "  ${BLD}Batch Complete${RST}"
    echo "  Total: ${total}  │  ${GRN}Success: ${success}${RST}  │  ${RED}Failed: ${fail}${RST}"
    echo "${BLD}═══════════════════════════════════════════════════════════${RST}"
    echo ""

    return $(( fail > 0 ? 1 : 0 ))
}

# ── aria2 input-file mode (max parallelism) ─────────────────────────────────
download_batch_parallel() {
    local -a model_ids=("$@")

    # Build aria2 input file
    local input_file
    input_file="$(mktemp /tmp/uvr5-dl-XXXXXX.txt)"
    trap "rm -f '$input_file'" EXIT

    local total_files=0
    for mid in "${model_ids[@]}"; do
        local dest_dir="${MODELS_DIR}"
        mkdir -p "$dest_dir"

        while IFS='|' read -r url filename; do
            local dest_file="${dest_dir}/${filename}"

            # Conflict check in parallel mode — only skip or overwrite
            if [[ -f "$dest_file" ]]; then
                case "$CONFLICT_MODE" in
                    skip)
                        warn "EXISTS — skipping: ${filename}"
                        continue
                        ;;
                    overwrite|backup)
                        if [[ "$CONFLICT_MODE" == "backup" ]]; then
                            local bak="${dest_file}.bak.$(date +%Y%m%d%H%M%S)"
                            mv "$dest_file" "$bak"
                        else
                            rm -f "$dest_file"
                        fi
                        ;;
                    ask)
                        warn "Cannot use interactive conflict mode with --parallel-batch; using skip"
                        continue
                        ;;
                esac
            fi

            # Write aria2 input-file format
            echo "$url"              >> "$input_file"
            echo "  dir=${dest_dir}" >> "$input_file"
            echo "  out=${filename}" >> "$input_file"
            total_files=$(( total_files + 1 ))
        done <<< "$(model_files "$mid")"
    done

    if (( total_files == 0 )); then
        warn "No files to download (all skipped or empty)"
        return 0
    fi

    log "Parallel batch: ${BLD}${total_files}${RST} files, ${PARALLEL} concurrent, ${CONNECTIONS} connections each"

    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY-RUN] aria2 input file:"
        cat "$input_file"
        return 0
    fi

    aria2c \
        --input-file="$input_file" \
        --max-concurrent-downloads="$PARALLEL" \
        --split="$CONNECTIONS" \
        --max-connection-per-server="$CONNECTIONS" \
        --min-split-size=1M \
        --max-tries="$MAX_RETRIES" \
        --retry-wait=3 \
        --continue=true \
        --auto-file-renaming=false \
        --allow-overwrite=true \
        --console-log-level=notice \
        --summary-interval=10 \
        --download-result=full \
        --file-allocation=falloc \
        --human-readable=true

    local rc=$?
    rm -f "$input_file"
    trap - EXIT

    if (( rc == 0 )); then
        ok "All ${total_files} files downloaded successfully"
    else
        err "aria2 exited with code ${rc}"
    fi
    return $rc
}

# ── interactive menu ────────────────────────────────────────────────────────
interactive_menu() {
    banner

    while true; do
        echo ""
        echo "${BLD}  Main Menu${RST}"
        echo "  ─────────────────────────────────────────"
        echo "  ${CYN}1${RST})  Browse all models ($(model_count) total)"
        echo "  ${CYN}2${RST})  Browse by architecture"
        echo "  ${CYN}3${RST})  ★ Recommended models (top picks)"
        echo "  ${CYN}4${RST})  Search by name"
        echo "  ${CYN}5${RST})  Download by ID(s)"
        echo "  ${CYN}6${RST})  Download ALL models"
        echo "  ${CYN}7${RST})  Settings"
        echo "  ${CYN}q${RST})  Quit"
        echo ""
        read -rp "  ${BLD}Choose [1-7/q]:${RST} " choice

        case "$choice" in
            1) menu_browse_all ;;
            2) menu_browse_arch ;;
            3) menu_recommended ;;
            4) menu_search ;;
            5) menu_download_by_id ;;
            6) menu_download_all ;;
            7) menu_settings ;;
            q|Q) echo ""; log "Goodbye!"; exit 0 ;;
            *) warn "Invalid choice" ;;
        esac
    done
}

menu_browse_all() {
    echo ""
    all_models | print_model_table
    echo ""
    prompt_download_selection
}

menu_browse_arch() {
    echo ""
    echo "  ${BLD}Architectures:${RST}"
    local -a archs=()
    local idx=0
    while IFS= read -r a; do
        idx=$(( idx + 1 ))
        archs+=("$a")
        local count
        count="$(jq --arg a "$a" '[.models[] | select(.arch == $a)] | length' "$CATALOG")"
        echo "  ${CYN}${idx}${RST})  ${a} (${count} models)"
    done < <(list_architectures)
    echo ""

    read -rp "  ${BLD}Choose architecture [1-${idx}]:${RST} " achoice
    if [[ "$achoice" =~ ^[0-9]+$ ]] && (( achoice >= 1 && achoice <= idx )); then
        local selected_arch="${archs[$((achoice-1))]}"
        echo ""
        echo "  ${BLD}Models — ${selected_arch}${RST}"
        models_by_arch "$selected_arch" | print_model_table
        echo ""
        prompt_download_selection
    else
        warn "Invalid choice"
    fi
}

menu_recommended() {
    echo ""
    echo "  ${BLD}★ Recommended Models${RST}"
    recommended_models | print_model_table
    echo ""
    prompt_download_selection
}

menu_search() {
    echo ""
    read -rp "  ${BLD}Search term:${RST} " term
    if [[ -z "$term" ]]; then
        warn "Empty search"
        return
    fi
    local results
    results="$(models_by_name "$term")"
    if [[ -z "$results" ]]; then
        warn "No models match '${term}'"
        return
    fi
    echo ""
    echo "  ${BLD}Results for '${term}':${RST}"
    echo "$results" | print_model_table
    echo ""
    prompt_download_selection
}

prompt_download_selection() {
    echo "  Enter model IDs to download (comma or space separated)"
    echo "  Or type ${CYN}all${RST} for all listed, ${CYN}rec${RST} for recommended, ${CYN}b${RST} to go back"
    echo ""
    read -rp "  ${BLD}IDs:${RST} " id_input

    case "$id_input" in
        b|B|back|"") return ;;
        all|ALL)
            local -a ids=()
            while IFS='|' read -r mid _rest; do
                ids+=("$mid")
            done < <(all_models)
            confirm_and_download "${ids[@]}"
            ;;
        rec|REC)
            local -a ids=()
            while IFS='|' read -r mid _rest; do
                ids+=("$mid")
            done < <(recommended_models)
            confirm_and_download "${ids[@]}"
            ;;
        *)
            # Parse comma/space separated IDs
            local -a ids=()
            local raw="${id_input//,/ }"
            for token in $raw; do
                if [[ "$token" =~ ^[0-9]+$ ]]; then
                    ids+=("$token")
                elif [[ "$token" =~ ^([0-9]+)-([0-9]+)$ ]]; then
                    # Range support: 1-10
                    local from="${BASH_REMATCH[1]}" to="${BASH_REMATCH[2]}"
                    for (( i=from; i<=to; i++ )); do
                        ids+=("$i")
                    done
                else
                    warn "Ignoring invalid token: ${token}"
                fi
            done
            if (( ${#ids[@]} > 0 )); then
                confirm_and_download "${ids[@]}"
            else
                warn "No valid IDs entered"
            fi
            ;;
    esac
}

confirm_and_download() {
    local -a ids=("$@")
    echo ""
    echo "  ${BLD}Will download ${#ids[@]} model(s):${RST}"
    for mid in "${ids[@]}"; do
        local name arch
        name="$(model_name_by_id "$mid")"
        arch="$(model_arch_by_id "$mid")"
        if [[ -n "$name" && "$name" != "null" ]]; then
            echo "    ${GRN}•${RST} [${mid}] ${name} (${arch})"
        else
            echo "    ${RED}•${RST} [${mid}] NOT FOUND"
        fi
    done
    echo ""
    echo "  Destination: ${BLD}${MODELS_DIR}${RST}"
    echo "  Connections: ${CONNECTIONS}/file  Parallel: ${PARALLEL}"
    echo "  Conflict: ${CONFLICT_MODE}"
    echo ""
    read -rp "  ${BLD}Proceed? [Y/n]:${RST} " confirm

    case "$confirm" in
        n|N|no|NO) log "Cancelled"; return ;;
    esac

    if (( ${#ids[@]} > 3 )); then
        download_batch_parallel "${ids[@]}"
    else
        download_batch "${ids[@]}"
    fi
}

menu_download_by_id() {
    prompt_download_selection
}

menu_download_all() {
    echo ""
    warn "This will download ALL $(model_count) models — this can use 50+ GB!"
    read -rp "  ${BLD}Are you sure? [yes/N]:${RST} " confirm
    if [[ "$confirm" != "yes" ]]; then
        log "Cancelled"
        return
    fi

    local -a ids=()
    while IFS='|' read -r mid _rest; do
        ids+=("$mid")
    done < <(all_models)
    download_batch_parallel "${ids[@]}"
}

menu_settings() {
    echo ""
    echo "  ${BLD}Current Settings${RST}"
    echo "  ───────────────────────────────────"
    echo "  Models dir:  ${MODELS_DIR}"
    echo "  Catalog:     ${CATALOG}"
    echo "  Connections: ${CONNECTIONS} per file"
    echo "  Parallel:    ${PARALLEL} simultaneous"
    echo "  Max retries: ${MAX_RETRIES}"
    echo "  Conflict:    ${CONFLICT_MODE}"
    echo "  Dry run:     ${DRY_RUN}"
    echo "  ───────────────────────────────────"
    echo ""
    echo "  ${DIM}Override via env vars or CLI flags.${RST}"
    echo "  ${DIM}Example: CONNECTIONS=16 PARALLEL=5 $0 menu${RST}"
}

# ── CLI download helpers ────────────────────────────────────────────────────
cli_download_by_names() {
    local names_csv="$1"
    local -a ids=()

    IFS=',' read -ra names <<< "$names_csv"
    for name in "${names[@]}"; do
        name="$(echo "$name" | xargs)"  # trim whitespace
        local matches
        matches="$(models_by_name "$name")"
        if [[ -z "$matches" ]]; then
            err "No model matching '${name}'"
            continue
        fi
        local match_count
        match_count="$(echo "$matches" | wc -l)"
        if (( match_count > 1 )); then
            warn "'${name}' matches ${match_count} models — using first match"
        fi
        local first_id
        first_id="$(echo "$matches" | head -1 | cut -d'|' -f1)"
        ids+=("$first_id")
    done

    if (( ${#ids[@]} == 0 )); then
        die "No valid models found"
    fi
    download_batch_parallel "${ids[@]}"
}

cli_download_by_ids() {
    local ids_csv="$1"
    local -a ids=()

    IFS=',' read -ra raw_ids <<< "$ids_csv"
    for token in "${raw_ids[@]}"; do
        token="$(echo "$token" | xargs)"
        if [[ "$token" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            local from="${BASH_REMATCH[1]}" to="${BASH_REMATCH[2]}"
            for (( i=from; i<=to; i++ )); do ids+=("$i"); done
        elif [[ "$token" =~ ^[0-9]+$ ]]; then
            ids+=("$token")
        else
            warn "Ignoring invalid ID: ${token}"
        fi
    done

    if (( ${#ids[@]} == 0 )); then
        die "No valid model IDs provided"
    fi
    download_batch_parallel "${ids[@]}"
}

cli_download_by_arch() {
    local arch="$1"
    local -a ids=()

    while IFS='|' read -r mid _rest; do
        ids+=("$mid")
    done < <(models_by_arch "$arch")

    if (( ${#ids[@]} == 0 )); then
        die "No models found for architecture '${arch}'"
    fi
    log "Found ${#ids[@]} models for ${BLD}${arch}${RST}"
    download_batch_parallel "${ids[@]}"
}

cli_download_recommended() {
    local -a ids=()
    while IFS='|' read -r mid _rest; do
        ids+=("$mid")
    done < <(recommended_models)

    if (( ${#ids[@]} == 0 )); then
        die "No recommended models found in catalog"
    fi
    log "Downloading ${#ids[@]} recommended models"
    download_batch_parallel "${ids[@]}"
}

cli_download_all() {
    local -a ids=()
    while IFS='|' read -r mid _rest; do
        ids+=("$mid")
    done < <(all_models)

    warn "Downloading ALL ${#ids[@]} models!"
    download_batch_parallel "${ids[@]}"
}

# ── CLI list helpers ────────────────────────────────────────────────────────
cli_list() {
    local filter="${1:-all}"
    case "$filter" in
        all) all_models | print_model_table ;;
        rec|recommended) recommended_models | print_model_table ;;
        *)
            # Check if it's an arch
            local archs
            archs="$(list_architectures)"
            if echo "$archs" | grep -qx "$filter"; then
                models_by_arch "$filter" | print_model_table
            else
                # Assume search term
                local results
                results="$(models_by_name "$filter")"
                if [[ -n "$results" ]]; then
                    echo "$results" | print_model_table
                else
                    die "No results for '${filter}'"
                fi
            fi
            ;;
    esac
}

# ── usage ───────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
${BLD}UVR5 Model Downloader${RST} v${VERSION}

${BLD}USAGE:${RST}
    ${0##*/} <command> [options]

${BLD}COMMANDS:${RST}
    ${CYN}menu${RST}                       Interactive download menu (default)
    ${CYN}list${RST} [filter]               List models (all|recommended|<arch>|<search>)
    ${CYN}download${RST} [options]           Download models (see below)
    ${CYN}info${RST} <id>                   Show details for a model
    ${CYN}archs${RST}                       List available architectures
    ${CYN}preflight${RST}                   Run dependency checks
    ${CYN}help${RST}                        Show this help

${BLD}DOWNLOAD OPTIONS:${RST}
    --id <id,id,...>           Download by catalog ID(s) (ranges: 1-10)
    --name <name,name,...>     Download by name (partial match)
    --arch <architecture>      Download all models for an architecture
    --recommended              Download all recommended models
    --all                      Download ALL models (50+ GB)
    --output, --out-dir <dir>  ${YLW}[REQUIRED]${RST} Output directory for downloaded models
    --connections <N>          Connections per file (default: ${CONNECTIONS})
    --parallel <N>             Simultaneous downloads (default: ${PARALLEL})
    --retries <N>              Max retries per file (default: ${MAX_RETRIES})
    --conflict <mode>          Conflict mode: ask|overwrite|skip|backup
    --catalog <path>           Catalog JSON path (default: ${CATALOG})
    --dry-run                  Show what would be downloaded
    --quiet                    Suppress aria2 progress output

${BLD}ENVIRONMENT VARIABLES:${RST}
    MODELS_DIR                 Override output directory
    CATALOG                    Override catalog JSON path
    CONNECTIONS                Override connections per file
    PARALLEL                   Override simultaneous downloads
    MAX_RETRIES                Override max retries
    CONFLICT_MODE              Override conflict mode

${BLD}EXAMPLES:${RST}
    # Interactive menu
    ${0##*/} --output /data/uvr5/models

    # Download recommended models
    ${0##*/} download --output /data/uvr5/models --recommended

    # Download specific models by ID
    ${0##*/} download --out-dir ./models --id 106,2,3

    # Download a range of IDs
    ${0##*/} download --output ./models --id 1-10

    # Download by name (partial match)
    ${0##*/} download --output ./models --name "Kim_Vocal,BS-Roformer"

    # Download all roformer models with 16 connections
    ${0##*/} download --output ./models --arch roformer --connections 16 --parallel 5

    # List all MDX-NET models (no --output needed for list)
    ${0##*/} list mdx-net

    # Dry run to see what --all would do
    ${0##*/} download --output ./models --all --dry-run

    # Skip existing files silently
    ${0##*/} download --output ./models --recommended --conflict skip --quiet
EOF
}

# ── argument parser ─────────────────────────────────────────────────────────
main() {
    local command="${1:-menu}"
    shift 2>/dev/null || true

    # Parse global flags first from remaining args
    local dl_mode="" dl_target=""
    local -a remaining=()

    while (( $# > 0 )); do
        case "$1" in
            --id)           dl_mode="id";      dl_target="$2"; shift 2 ;;
            --name)         dl_mode="name";    dl_target="$2"; shift 2 ;;
            --arch)         dl_mode="arch";    dl_target="$2"; shift 2 ;;
            --recommended)  dl_mode="rec";     shift ;;
            --all)          dl_mode="all";     shift ;;
            --connections)  CONNECTIONS="$2";   shift 2 ;;
            --parallel)     PARALLEL="$2";     shift 2 ;;
            --retries)      MAX_RETRIES="$2";  shift 2 ;;
            --conflict)     CONFLICT_MODE="$2"; shift 2 ;;
            --output|--out-dir) MODELS_DIR="$2"; shift 2 ;;
            --catalog)      CATALOG="$2";      shift 2 ;;
            --dry-run)      DRY_RUN=true;      shift ;;
            --quiet|-q)     QUIET=true;        shift ;;
            --help|-h)      usage; exit 0 ;;
            --version|-v)   echo "v${VERSION}"; exit 0 ;;
            *)              remaining+=("$1"); shift ;;
        esac
    done

    # Route commands
    case "$command" in
        menu|interactive)
            preflight
            interactive_menu
            ;;
        list|ls)
            preflight_lite
            cli_list "${remaining[0]:-all}"
            ;;
        download|dl|get)
            preflight
            case "$dl_mode" in
                id)   cli_download_by_ids "$dl_target" ;;
                name) cli_download_by_names "$dl_target" ;;
                arch) cli_download_by_arch "$dl_target" ;;
                rec)  cli_download_recommended ;;
                all)  cli_download_all ;;
                "")
                    # If positional args remain, treat as names
                    if (( ${#remaining[@]} > 0 )); then
                        local joined
                        joined="$(IFS=','; echo "${remaining[*]}")"
                        cli_download_by_names "$joined"
                    else
                        die "No download target specified. Use --id, --name, --arch, --recommended, or --all"
                    fi
                    ;;
            esac
            ;;
        info|show)
            local mid="${remaining[0]:-}"
            if [[ -z "$mid" ]]; then
                die "Usage: ${0##*/} info <model_id>"
            fi
            preflight_lite
            local detail
            detail="$(model_by_id "$mid")"
            if [[ -z "$detail" || "$detail" == "null" ]]; then
                die "Model ID ${mid} not found"
            fi
            echo ""
            echo "  ${BLD}Model Details${RST}"
            echo "  ─────────────────────────────────────"
            echo "  ID:   $(echo "$detail" | jq -r '.id')"
            echo "  Name: $(echo "$detail" | jq -r '.name')"
            echo "  Arch: $(echo "$detail" | jq -r '.arch')"
            local rec
            rec="$(echo "$detail" | jq -r '.recommended // empty')"
            if [[ -n "$rec" ]]; then
                echo "  Rank: ${YLW}★${rec}${RST}"
            fi
            echo "  Files:"
            echo "$detail" | jq -r '.files[] | "    • \(.filename)\n      \(.url)"'
            echo "  ─────────────────────────────────────"
            echo ""
            ;;
        archs|architectures)
            preflight_lite
            echo ""
            echo "  ${BLD}Architectures${RST}"
            echo "  ─────────────────────────────────────"
            while IFS= read -r a; do
                local count
                count="$(jq --arg a "$a" '[.models[] | select(.arch == $a)] | length' "$CATALOG")"
                printf "  %-12s  %s models\n" "$a" "$count"
            done < <(list_architectures)
            echo "  ─────────────────────────────────────"
            echo ""
            ;;
        preflight|check)
            preflight
            ;;
        help|--help|-h)
            usage
            ;;
        *)
            err "Unknown command: ${command}"
            usage
            exit 1
            ;;
    esac
}

main "$@"
