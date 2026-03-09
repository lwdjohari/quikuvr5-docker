# UVR5 Model Downloader

Pro-grade aria2 batch downloader for UVR5 vocal separation models. Supports interactive menu, CLI arguments, resumable downloads, parallel transfers, and conflict handling. 

Why? Sometime you would face conditions that you are need deterministic downloader because of internet connections or other use-cases.

## Model Catalog

All 145 models from UVR5-UI v1.8.4 are indexed in `model-catalog.json`, organized by architecture:

| Architecture | Models | Description |
|---|---|---|
| `roformer` | 73 | BS-Roformer & MelBand Roformer — best quality vocal/instrument separation |
| `mdx-net` | 39 | MDX-NET ONNX models — fast inference, great vocal isolation |
| `vr-arch` | 28 | VR Architecture — echo/reverb removal, de-noise, legacy vocal separation |
| `mdx23c` | 5 | MDX23C — high-fidelity instrument/vocal separation (8K FFT) |

### ★ Recommended Models (Top Picks)

| Rank | Model | Architecture | Use Case |
|---|---|---|---|
| ★1 | Kim_Vocal_2.onnx | mdx-net | Best general vocal extraction |
| ★2 | BS-Roformer-Viperx-1296 | roformer | Highest SDR vocal separation |
| ★3 | MDX23C-8KFFT-InstVoc_HQ_2 | mdx23c | High-fidelity instrument/vocal split |
| ★5 | Kim_Inst.onnx | mdx-net | Instrument extraction (complement of ★1) |
| ★6 | BS-Roformer-Viperx-1053 | roformer | Multi-stem separation (vocals/drums/bass/other) |
| ★7 | Reverb_HQ_By_FoxJoy.onnx | mdx-net | Reverb removal (post-processing) |
| ★8 | UVR-De-Echo-Aggressive.pth | vr-arch | Echo removal (post-processing) |
| ★9 | MDX23C-8KFFT-InstVoc_HQ | mdx23c | Alternative high-fidelity vocal split |
| ★10 | UVR-MDX-NET-Voc_FT.onnx | mdx-net | Fine-tuned vocal extraction |

## Requirements

- **aria2c** — multi-connection downloader
  - Ubuntu/Debian: `sudo apt install aria2`
  - macOS: `brew install aria2`
- **jq** — JSON processor
  - Ubuntu/Debian: `sudo apt install jq`
  - macOS: `brew install jq`

Run `preflight` to verify everything:

```bash
./model-downloader.sh preflight
```

## Quick Start

```bash
# Make executable
chmod +x model-downloader.sh

# Launch interactive menu
./model-downloader.sh --output /data/uvr5/models

# Download recommended models (best starting set)
./model-downloader.sh download --output /data/uvr5/models --recommended

# Download a specific model by ID
./model-downloader.sh download --output ./models --id 106

# Download multiple by ID (comma-separated or range)
./model-downloader.sh download --out-dir ./models --id 106,107,108
./model-downloader.sh download --out-dir ./models --id 1-10

# Download by name (partial match, case-insensitive)
./model-downloader.sh download --output ./models --name "Kim_Vocal"

# Download all models for an architecture
./model-downloader.sh download --output ./models --arch roformer

# Dry run — see what would be downloaded without touching disk
./model-downloader.sh download --output ./models --recommended --dry-run

# List commands don't need --output
./model-downloader.sh list recommended
./model-downloader.sh archs
```

## Interactive Menu

Run without arguments (or with `menu`) to get a full interactive TUI:

```bash
./model-downloader.sh
```

```
    ╔══════════════════════════════════════════════════╗
    ║       UVR5 Model Downloader v1.0.0               ║
    ║       Aria2 Toolkit Batch Downloader             ║
    ╚══════════════════════════════════════════════════╝

  Main Menu
  ─────────────────────────────────────────
  1)  Browse all models (145 total)
  2)  Browse by architecture
  3)  ★ Recommended models (top picks)
  4)  Search by name
  5)  Download by ID(s)
  6)  Download ALL models
  7)  Settings
  q)  Quit
```

The menu supports:
- Browsing with formatted tables (ID, name, arch, file count, rank)
- Downloading by entering IDs: `106`, `1,2,3`, `1-10`, `all`, `rec`
- Confirmation prompt before starting downloads

## Commands

| Command | Description |
|---|---|
| `menu` | Interactive download menu *(default)* |
| `list [filter]` | List models — `all`, `recommended`, `<arch>`, `<search>` |
| `download` | Download models (see options below) |
| `info <id>` | Show full details for a model |
| `archs` | List available architectures with counts |
| `preflight` | Run dependency & environment checks |
| `help` | Show usage help |

## Download Options

```
--output, --out-dir <dir>  [REQUIRED] Output directory for downloaded models
--id <id,id,...>           Download by catalog ID (supports ranges: 1-10)
--name <name,name,...>     Download by name (partial match, case-insensitive)
--arch <architecture>      Download all models for an architecture
--recommended              Download all ★ recommended models
--all                      Download ALL 145 models (50+ GB)
--connections <N>          Connections per file (default: 8)
--parallel <N>             Simultaneous downloads (default: 3)
--retries <N>              Max retries per file (default: 5)
--conflict <mode>          Conflict mode: ask|overwrite|skip|backup
--catalog <path>           Custom catalog JSON path
--dry-run                  Show what would be downloaded
--quiet                    Suppress aria2 progress output
```

> **Note:** `--output` / `--out-dir` is required for all download and interactive commands.
> Read-only commands (`list`, `info`, `archs`) do not require it.

## Conflict Handling

When a model file already exists, the `--conflict` flag controls behavior:

| Mode | Behavior |
|---|---|
| `ask` | Interactive prompt: skip / overwrite / backup / skip-all *(default)* |
| `skip` | Silently skip existing files |
| `overwrite` | Delete existing and re-download |
| `backup` | Rename existing to `.bak.<timestamp>` and download fresh |

```bash
# Skip everything that already exists
./model-downloader.sh download --output ./models --recommended --conflict skip

# Overwrite all without asking
./model-downloader.sh download --output ./models --id 1-5 --conflict overwrite

# Backup existing before re-downloading
./model-downloader.sh download --output ./models --id 106 --conflict backup
```

## Performance Tuning

aria2 is configured for maximum throughput by default:

| Setting | Default | Flag |
|---|---|---|
| Connections per file | 8 | `--connections` |
| Simultaneous downloads | 3 | `--parallel` |
| Max retries | 5 | `--retries` |
| File allocation | `falloc` | — |
| Resume support | always on | — |

For faster downloads on high-bandwidth connections:

```bash
# 16 connections per file, 5 simultaneous downloads
./model-downloader.sh download --output ./models --recommended --connections 16 --parallel 5
```

For slower or metered connections:

```bash
# Conservative: 2 connections, 1 at a time
./model-downloader.sh download --output ./models --recommended --connections 2 --parallel 1
```

## Environment Variables

All options can be overridden via environment variables:

```bash
export MODELS_DIR=/data/uvr5/models       # overrides --output / --out-dir
export CATALOG=/path/to/custom/model-catalog.json
export CONNECTIONS=16
export PARALLEL=5
export MAX_RETRIES=10
export CONFLICT_MODE=skip
```

## Catalog Format

The catalog is a flat JSON file (`model-catalog.json`) designed for easy maintenance:

```json
{
  "_meta": {
    "version": "1.1.0",
    "source": "UVR5-UI v1.8.4 models.json"
  },
  "models": [
    {
      "id": 106,
      "name": "Kim_Vocal_2.onnx",
      "arch": "mdx-net",
      "recommended": 1,
      "files": [
        {
          "url": "https://github.com/.../Kim_Vocal_2.onnx",
          "filename": "Kim_Vocal_2.onnx"
        }
      ]
    }
  ]
}
```

### Adding a Model

Add an entry to the `models` array in `model-catalog.json`:

```json
{
  "id": 146,
  "name": "My-Custom-Model",
  "arch": "roformer",
  "files": [
    {
      "url": "https://example.com/model.ckpt",
      "filename": "model.ckpt"
    },
    {
      "url": "https://example.com/model.yaml",
      "filename": "model.yaml"
    }
  ]
}
```

- `id` — unique integer (increment from last)
- `name` — display name (used for search)
- `arch` — architecture tag (`roformer`, `mdx-net`, `mdx23c`, `vr-arch`)
- `recommended` — *(optional)* rank number for top picks
- `files` — array of `{url, filename}` objects (multi-file models need all files)

## Usage Examples

```bash
# See what's available for roformer
./model-downloader.sh list roformer

# Get details on a specific model
./model-downloader.sh info 1

# Download the top 3 recommended to a custom directory
./model-downloader.sh download --output /data/models --id 106,2,76

# Download all VR-arch models (echo/reverb removal)
./model-downloader.sh download --output ./models --arch vr-arch

# Dry-run all 145 models to see total file count
./model-downloader.sh download --output ./models --all --dry-run

# Search for reverb models
./model-downloader.sh list reverb

# Quiet mode for CI/scripts
./model-downloader.sh download --output ./models --recommended --conflict skip --quiet
```

## Expected Models Folder Structure

UVR5 expects all models in a **single flat directory** — no architecture subfolders. The downloader places every file directly into the `--output` directory.

After downloading the recommended set, your models folder will look like:

```
models/
├── Kim_Vocal_2.onnx                              # ★1  mdx-net   — best vocal extraction
├── Kim_Inst.onnx                                  # ★5  mdx-net   — instrument extraction
├── Reverb_HQ_By_FoxJoy.onnx                       # ★7  mdx-net   — reverb removal
├── UVR-MDX-NET-Voc_FT.onnx                        # ★10 mdx-net   — fine-tuned vocals
├── model_bs_roformer_ep_368_sdr_12.9628.ckpt       # ★2  roformer  — highest SDR vocals
├── model_bs_roformer_ep_368_sdr_12.9628.yaml       #     roformer  — config (paired with .ckpt)
├── model_bs_roformer_ep_937_sdr_10.5309.ckpt       # ★6  roformer  — multi-stem separation
├── model_bs_roformer_ep_937_sdr_10.5309.yaml       #     roformer  — config (paired with .ckpt)
├── MDX23C-8KFFT-InstVoc_HQ.ckpt                    # ★9  mdx23c    — high-fidelity vocal split
├── MDX23C-8KFFT-InstVoc_HQ_2.ckpt                  # ★3  mdx23c    — high-fidelity vocal split v2
├── model_2_stem_full_band_8k.yaml                  #     mdx23c    — config (shared by MDX23C models)
└── UVR-De-Echo-Aggressive.pth                      # ★8  vr-arch   — echo removal
```

After downloading all 145 models, the full tree will contain:

```
models/
├── *.onnx              ×39 files   — MDX-NET models (single-file, ready to use)
├── *.pth               ×28 files   — VR Architecture models (single-file)
├── *.ckpt + *.yaml     ×78 pairs   — Roformer & MDX23C models (always paired)
│
│   # File type breakdown:
│   #   .onnx  — ONNX runtime models (MDX-NET)
│   #   .pth   — PyTorch state dicts (VR Architecture)
│   #   .ckpt  — PyTorch checkpoints (Roformer, MDX23C)
│   #   .yaml  — Model config files (paired with .ckpt files)
│
└── 223 files total, ~50+ GB
```

> **Important:** Roformer and MDX23C models require both the `.ckpt` **and** `.yaml` files to work.
> The downloader always fetches both files together — never download `.ckpt` files alone.

### Docker Volume Mapping

When using the UVR5 Docker container, map your host models directory:

```bash
# In .env
HOST_MODELS=/data/uvr5/models

# The entrypoint symlinks: container's ./models → /data/models (volume mount)
# So files at /data/uvr5/models/ on host appear as ./models/ inside the container
```

## UVR5 Workflow

```bash
# 1. Download recommended models to your host models directory
./toolkit/model-downloader.sh download --output /data/uvr5/models --recommended

# 2. Models land in /data/uvr5/models/ (symlinked into container via HOST_MODELS)

# 3. Start UVR5
./run-quikuvr5.sh start

# 4. Models appear in the UVR5 web UI model selector automatically
```

## Resuming Interrupted Downloads

aria2 creates `.aria2` control files alongside partial downloads. If a download is interrupted (Ctrl+C, network drop, power loss), simply re-run the same command — aria2 will resume from where it left off:

```bash
# First run — interrupted at 40%
./model-downloader.sh download --output ./models --recommended
# ^C

# Second run — resumes from 40%
./model-downloader.sh download --output ./models --recommended --conflict skip
```

The `--conflict skip` flag ensures already-completed files are not re-downloaded.
