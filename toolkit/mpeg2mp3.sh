#!/usr/bin/env bash
#
# mpeg2mp3.sh
#
# Professional MPEG → MP3 converter
#
# Features
# --------
# • Automatically detects the source codec.
# • Lossless remux if the audio is already MP3.
# • Re-encode only when necessary (LAME V0).
# • Never resamples unless explicitly requested.
# • Preserves metadata.
# • Atomic output (temporary file + rename).
# • Validates ffmpeg/ffprobe availability.
# • Safe handling of spaces and special characters.
#
# Usage:
#   ./mpeg2mp3.sh input.mpeg
#

set -Eeuo pipefail
IFS=$'\n\t'

###############################################################################
# Logging
###############################################################################

log()  { printf '[INFO]  %s\n' "$*"; }
warn() { printf '[WARN]  %s\n' "$*" >&2; }
die()  { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

cleanup() {
    [[ -n "${TMP:-}" && -f "${TMP}" ]] && rm -f -- "${TMP}"
}
trap cleanup EXIT

###############################################################################
# Requirements
###############################################################################

command -v ffmpeg  >/dev/null || die "ffmpeg not found"
command -v ffprobe >/dev/null || die "ffprobe not found"

[[ $# -eq 1 ]] || die "Usage: $0 <input-file>"

INPUT="$(readlink -f -- "$1")"

[[ -f "$INPUT" ]] || die "Input file not found."

###############################################################################
# Paths
###############################################################################

DIR="$(dirname -- "$INPUT")"
BASE="$(basename -- "$INPUT")"
NAME="${BASE%.*}"

OUT="${DIR}/${NAME}.mp3"
TMP="${DIR}/.${NAME}.tmp.$$.$RANDOM.mp3"

###############################################################################
# Probe
###############################################################################

codec="$(
ffprobe \
    -v error \
    -select_streams a:0 \
    -show_entries stream=codec_name \
    -of default=noprint_wrappers=1:nokey=1 \
    "$INPUT"
)"

[[ -n "$codec" ]] || die "No audio stream found."

sample_rate="$(
ffprobe \
    -v error \
    -select_streams a:0 \
    -show_entries stream=sample_rate \
    -of default=noprint_wrappers=1:nokey=1 \
    "$INPUT"
)"

bitrate="$(
ffprobe \
    -v error \
    -select_streams a:0 \
    -show_entries stream=bit_rate \
    -of default=noprint_wrappers=1:nokey=1 \
    "$INPUT"
)"

channels="$(
ffprobe \
    -v error \
    -select_streams a:0 \
    -show_entries stream=channels \
    -of default=noprint_wrappers=1:nokey=1 \
    "$INPUT"
)"

###############################################################################
# Diagnostics
###############################################################################

echo "========================================================"
echo " MPEG → MP3 Professional Converter"
echo "========================================================"
echo
printf "Input      : %s\n" "$INPUT"
printf "Output     : %s\n" "$OUT"
printf "Codec      : %s\n" "$codec"
printf "SampleRate : %s Hz\n" "${sample_rate:-unknown}"
printf "Channels   : %s\n" "${channels:-unknown}"

if [[ -n "${bitrate}" && "${bitrate}" != "N/A" ]]; then
    printf "Bitrate    : %.0f kbps\n" "$((bitrate/1000))"
fi

echo

###############################################################################
# Convert
###############################################################################

case "$codec" in

    mp3)

        log "Audio already MP3 — performing lossless stream copy."

        ffmpeg \
            -hide_banner \
            -nostdin \
            -loglevel warning \
            -y \
            -i "$INPUT" \
            -map 0:a:0 \
            -vn \
            -c:a copy \
            -map_metadata 0 \
            -id3v2_version 3 \
            -write_xing 1 \
            -f mp3 \
            "$TMP"
        ;;

    *)

        log "Re-encoding with libmp3lame (V0, transparent quality)."

        ffmpeg \
            -hide_banner \
            -nostdin \
            -loglevel warning \
            -y \
            -i "$INPUT" \
            -map 0:a:0 \
            -vn \
            -c:a libmp3lame \
            -q:a 0 \
            -map_metadata 0 \
            -id3v2_version 3 \
            -write_xing 1 \
            -f mp3 \
            "$TMP"
        ;;
esac

###############################################################################
# Validation
###############################################################################

ffprobe -v error "$TMP" >/dev/null \
    || die "Output validation failed."

mv -f -- "$TMP" "$OUT"

###############################################################################
# Summary
###############################################################################

echo
echo "========================================================"
echo " Conversion completed successfully"
echo "========================================================"

printf "Output : %s\n" "$OUT"

size="$(stat -c '%s' "$OUT")"

printf "Size   : %.2f MB\n" \
    "$(awk "BEGIN{print ${size}/1024/1024}")"

echo