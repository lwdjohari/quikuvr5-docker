# Audio Conversion Toolkit

Versatile audio/video conversion toolkit using `ffmpeg` with configurable encoding profiles and full preflight auditing without headache.

## Supported Conversions

| From | To | Use Case |
|---|---|---|
| MP4, MKV, AVI, MOV, FLV, WEBM | MP3 | Extract audio from video |
| MP4, MKV, AVI, MOV, FLV, WEBM | WAV | Extract lossless audio from video |
| WAV, FLAC, OGG, AAC | MP3 | Compress lossless to lossy |
| MP3, FLAC, OGG, AAC | WAV | Decode to lossless |

## Quick Start

```bash
# Make executable
chmod +x audio-convert.sh

# Run preflight audit (recommended first time)
./audio-convert.sh preflight

# Convert video to MP3 V0 (default)
./audio-convert.sh video.mp4

# Convert to high-quality WAV
./audio-convert.sh --profile wav-hq song.mp3

# Convert WAV to MP3 320 CBR
./audio-convert.sh --profile mp3-320 vocals.wav

# Batch convert a folder
./audio-convert.sh --batch ./raw/ --profile mp3-v0 --output ./converted/

# List all profiles
./audio-convert.sh --list-profiles
```

## Preflight Audit

Run `preflight` before your first conversion to verify all dependencies and get actionable fix recommendations for any issues:

```bash
./audio-convert.sh preflight
./audio-convert.sh preflight --output /data/uvr5/outputs/
```

The audit checks 7 areas:

| Check | What it verifies |
|---|---|
| **ffmpeg binary** | Installed and on PATH |
| **ffmpeg version** | Version 4.0+ recommended |
| **Audio encoders** | `libmp3lame`, `pcm_s16le`, `pcm_s24le`, `pcm_f32le` |
| **Audio decoders** | `mp3`, `pcm_s16le`, `aac`, `flac`, `vorbis` |
| **Profiles config** | `profiles.conf` exists, readable, all profiles parse correctly |
| **Disk space** | Free space at output location (warns if < 500 MB) |
| **Output directory** | Exists and writable, or parent writable for creation |

Every error includes a `↳ fix:` hint with the exact command to run.

## Profiles

Edit `profiles.conf` to customize or add profiles.

| Profile | Format | Mode | Rate | Sample | Ch | Depth |
|---|---|---|---|---|---|---|
| `mp3-v0` | MP3 | VBR | V0 (~245k) | 44100 | 2 | - |
| `mp3-v2` | MP3 | VBR | V2 (~190k) | 44100 | 2 | - |
| `mp3-320` | MP3 | CBR | 320k | 44100 | 2 | - |
| `mp3-192` | MP3 | CBR | 192k | 44100 | 2 | - |
| `mp3-128` | MP3 | CBR | 128k | 44100 | 2 | - |
| `mp3-mono` | MP3 | VBR | V0 | 44100 | 1 | - |
| `wav-cd` | WAV | PCM | - | 44100 | 2 | 16-bit |
| `wav-hq` | WAV | PCM | - | 48000 | 2 | 24-bit |
| `wav-32` | WAV | PCM | - | 48000 | 2 | 32-bit float |
| `wav-mono` | WAV | PCM | - | 44100 | 1 | 16-bit |

### Custom Profile Example

Add to `profiles.conf`:

```ini
[mp3-podcast]
# Mono voice, small files
format      = mp3
mode        = vbr
quality     = 4
samplerate  = 22050
channels    = 1
```

Then use it: `./audio-convert.sh --profile mp3-podcast interview.wav`

## All Options

```
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
```

## Requirements

- `ffmpeg` with `libmp3lame` encoder
  - Ubuntu/Debian: `sudo apt install ffmpeg`
  - macOS: `brew install ffmpeg`
  - Already included in the UVR5 Docker image
  - Windows? Help me to write it 😬

## UVR5 Workflow Example

```bash
# 1. Extract vocals with UVR5 (outputs to /data/uvr5/outputs/)
# 2. Convert separated vocals to MP3 V0
./audio-convert.sh --batch /data/uvr5/outputs/ --profile mp3-v0 --output /data/uvr5/final/

# Or convert video input first, then process
./audio-convert.sh --profile wav-cd video.mp4 --output /data/uvr5/inputs/
```
