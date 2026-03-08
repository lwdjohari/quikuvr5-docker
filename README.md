# quikuvr5

Production-ready Docker setup for [UVR5-UI](https://github.com/Eddycrack864/UVR5-UI) (Ultimate Vocal Remover 5 - Gradio WebUI).

## Features

- **GPU-accelerated** vocal separation via NVIDIA CUDA
- **CPU fallback** for environments without a GPU
- Non-root container execution (`appuser`)
- Persistent host-mounted volumes for models, inputs, outputs, and caches
- Build-time and runtime validation of all dependencies
- Graceful shutdown via `tini` init process
- Health checks for orchestrator integration (300s start period for ML model loading)
- Structured logging with rotation (50 MB × 5 files)
- **Preflight audit** - checks all host deps and recommends fixes
- Supports both **rootless Docker** and **sudo docker** automatically
- Configurable **bind address** - restrict to localhost or expose to LAN
- Optional **runtime import skip** for faster container startup
- Precompiled Python bytecode for faster app launch
- Minimal env leakage - only required vars passed into the container
- **Git ref pinning** - lock builds to a specific tag, branch, or commit SHA

## Prerequisites

| Requirement | Minimum |
|---|---|
| Docker Engine | 24.0+ |
| Docker Compose | v2.20+ (`docker compose`, not `docker-compose`) |
| NVIDIA Driver | 525+ (GPU mode only) |
| NVIDIA Container Toolkit | 1.14+ (GPU mode only) |

## Quick Start

```bash
# 1. Clone
git clone https://github.com/lwdjohari/quikuvr5-docker.git
cd quikuvr5-docker

# 2. Configure
cp .env.example .env
# Edit .env - set HOST_* paths, APP_UID/APP_GID, USE_GPU, etc.

# 3. Run preflight check (recommended first time)
./run-quikuvr5.sh preflight

# 4. Build
./run-quikuvr5.sh build

# 5. Run
./run-quikuvr5.sh run        # interactive (foreground)
./run-quikuvr5.sh start      # detached (background, auto-restart)

# 6. Open browser
# http://localhost:7860
```

## Configuration

All configuration is done via the `.env` file. Copy `.env.example` and adjust:

| Variable | Default | Description |
|---|---|---|
| `IMAGE_NAME` | `uvr5-industrial` | Docker image name |
| `CONTAINER_NAME` | `uvr5` | Container name |
| `UVR_PORT` | `7860` | Gradio WebUI port |
| `BIND_ADDRESS` | `0.0.0.0` | Host-side bind address (`127.0.0.1` = localhost only) |
| `APP_UID` | `1000` | Container user UID (match host user) |
| `APP_GID` | `1000` | Container user GID (match host group) |
| `USE_GPU` | `true` | Enable NVIDIA GPU passthrough |
| `ENABLE_BUILD_TOOLS` | `false` | Install build-essential, cmake, etc. |
| `SKIP_RUNTIME_VALIDATION` | `false` | Skip import validation on startup (saves ~5–10 s) |
| `UVR5_GIT_REPO` | `https://github.com/Eddycrack864/UVR5-UI.git` | Git repo URL to clone (change to use a fork) |
| `UVR5_GIT_REF` | *(empty)* | Pin repo to tag/branch/SHA (empty = latest main) |
| `HOST_MODELS` | `/data/uvr5/models` | Host path for model files |
| `HOST_INPUTS` | `/data/uvr5/inputs` | Host path for input audio |
| `HOST_OUTPUTS` | `/data/uvr5/outputs` | Host path for separated audio |
| `HOST_CACHE` | `/data/uvr5/cache` | Host path for app cache |
| `HOST_PIP_CACHE` | `/data/uvr5/pip-cache` | Host path for pip cache (used by `docker exec ... pip install`) |

> **Important:** `APP_UID`/`APP_GID` are used instead of `UID`/`GID` because `$UID` is a read-only bash built-in.

> **Important:** Do not use variable interpolation (e.g., `${HOST_BASE}/models`) in `.env` - Docker Compose does not support it.

## CLI Reference

### `run-quikuvr5.sh`

```bash
# Setup & Diagnostics
./run-quikuvr5.sh preflight    # Full host dependency audit with fix recommendations
./run-quikuvr5.sh check        # Show current configuration
./run-quikuvr5.sh status       # Show container runtime status

# Build & Deploy
./run-quikuvr5.sh build        # Build the Docker image
./run-quikuvr5.sh validate     # Run in-container validation (one-shot)
./run-quikuvr5.sh run          # Start interactively (foreground, auto-remove)
./run-quikuvr5.sh start        # Start detached (background, auto-restart)

# Operations
./run-quikuvr5.sh stop         # Stop the running container
./run-quikuvr5.sh restart      # Restart the container
./run-quikuvr5.sh logs         # Follow container logs
./run-quikuvr5.sh shell        # Open bash in running container

./run-quikuvr5.sh help         # Show help
```

### Docker Compose

```bash
docker compose build
docker compose up -d
docker compose down
docker compose logs -f uvr5
docker compose exec uvr5 bash
```

### CPU-only deployment

```bash
docker compose -f docker-compose.yml -f docker-compose.cpu.yml up -d
```

## Container Commands

The entrypoint accepts these commands:

| Command | Description |
|---|---|
| `start` | Launch Gradio WebUI (default) |
| `validate` | Run full validation then exit |
| `info` | Print PyTorch/CUDA diagnostics |
| `shell` | Drop into bash |

## Volume Layout

```
/data/
├── models/      ← Pre-trained separation models
├── inputs/      ← Audio files to process
├── outputs/     ← Separated audio results
├── cache/       ← Application cache
└── pip-cache/   ← pip download cache (for runtime `pip install` via exec)
```

## Security

### Bind address

By default the port is exposed on all interfaces (`0.0.0.0`). For production, restrict to localhost and use a reverse proxy:

```env
BIND_ADDRESS=127.0.0.1
```

### Environment isolation

The Compose file passes **only** `UVR_PORT` and `SKIP_RUNTIME_VALIDATION` into the container. Host paths, UIDs, and build flags are never leaked at runtime.

### Non-root execution

The container runs as `appuser` (configurable via `APP_UID`/`APP_GID`). No process inside the container runs as root.

## Performance Tips

| Tip | How |
|---|---|
| Skip import validation once stable | `SKIP_RUNTIME_VALIDATION=true` in `.env` (saves ~5–10 s per start) |
| Pin a known-good release | `UVR5_GIT_REF=v1.0.0` for reproducible builds |
| Pre-download models | Place `.pth` files in `HOST_MODELS` before first run |
| Use pip cache volume | `HOST_PIP_CACHE` avoids re-downloading packages on rebuild |
| Precompiled bytecode | Enabled by default - PyTorch/Gradio `.pyc` files are generated at build time |

## Troubleshooting

### Run the preflight check first
```bash
./run-quikuvr5.sh preflight
```
This will audit all host dependencies, Docker access, GPU stack, disk space, directory permissions, and image status - with actionable fix recommendations for every issue found.

### Container won't start / keeps restarting
```bash
./run-quikuvr5.sh validate
./run-quikuvr5.sh logs
ls -la /data/uvr5/
```

> **Note:** The healthcheck has a 300-second start period to allow for ML model loading on first cold start. If the container is still restarting after 5 minutes, check the logs for errors.

### GPU not detected
```bash
nvidia-smi
docker run --rm --gpus all nvidia/cuda:12.1.0-base-ubuntu22.04 nvidia-smi
```

### Permission denied on volumes
```bash
# Match APP_UID/APP_GID to your host user
id -u    # → set APP_UID to this value
id -g    # → set APP_GID to this value

# Fix ownership
sudo chown -R $(id -u):$(id -g) /data/uvr5/
```

### Docker access without sudo
```bash
sudo usermod -aG docker $(whoami)
newgrp docker
```

## Included Toolkit

The `toolkit/` directory contains standalone utility scripts for audio processing workflows.

### Audio Conversion Toolkit

`toolkit/audio-convert.sh` - Convert between video/audio formats with configurable encoding profiles.

```bash
# Run preflight audit
./toolkit/audio-convert.sh preflight

# Convert MP4 video to MP3 V0
./toolkit/audio-convert.sh toolkit/audio-convert.sh video.mp4

# Convert WAV to MP3 320 CBR
./toolkit/audio-convert.sh --profile mp3-320 vocals.wav

# Convert MP3 to lossless WAV
./toolkit/audio-convert.sh --profile wav-hq song.mp3

# Batch convert UVR5 output folder
./toolkit/audio-convert.sh --batch /data/uvr5/outputs/ --profile mp3-v0 --output /data/uvr5/final/

# List all encoding profiles
./toolkit/audio-convert.sh --list-profiles
```

**Features:**
- 10 built-in profiles: `mp3-v0`, `mp3-v2`, `mp3-320`, `mp3-192`, `mp3-128`, `mp3-mono`, `wav-cd`, `wav-hq`, `wav-32`, `wav-mono`
- Batch conversion with `--batch` and `--recursive`
- Full preflight audit (ffmpeg, encoders, decoders, profiles, disk space, permissions)
- Dry-run mode, overwrite control, custom output directory
- Custom profiles via `toolkit/profiles.conf`

See [`toolkit/README.md`](toolkit/README.md) for full documentation.

## License

See [LICENSE](LICENSE).
