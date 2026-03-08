"""Build-time UVR5 import validation."""
import importlib
import os
import sys

# Library modules — importable from anywhere
LIBRARY_MODULES = [
    "gradio",
    "torch",
    "yt_dlp",
    "audio_separator.separator",
]

# Local app modules — require UVR_HOME on sys.path
LOCAL_MODULES = [
    "assets.themes.loadThemes",
    "assets.i18n.i18n",
]


def main():
    # Add UVR_HOME to sys.path so local app modules are importable
    uvr_home = os.environ.get("UVR_HOME", "/opt/UVR5-UI")
    if uvr_home not in sys.path:
        sys.path.insert(0, uvr_home)

    missing = []
    for m in LIBRARY_MODULES + LOCAL_MODULES:
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
