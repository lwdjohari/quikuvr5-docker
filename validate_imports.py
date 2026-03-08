"""Build-time UVR5 import validation."""
import importlib
import sys

REQUIRED_MODULES = [
    "gradio",
    "torch",
    "yt_dlp",
    "audio_separator.separator",
    "assets.themes.loadThemes",
    "assets.i18n.i18n",
]


def main():
    missing = []
    for m in REQUIRED_MODULES:
        try:
            importlib.import_module(m)
        except Exception as e:
            missing.append(f"  {m}: {e}")
    if missing:
        print("UVR5 import validation FAILED:", file=sys.stderr)
        print("\n".join(missing), file=sys.stderr)
        sys.exit(1)
    print("UVR5 import validation passed")


if __name__ == "__main__":
    main()
