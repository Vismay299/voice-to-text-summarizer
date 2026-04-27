#!/usr/bin/env bash
set -euo pipefail

REPO="Vismay299/speakflow"
API_URL="https://api.github.com/repos/${REPO}/releases/latest"
APP_NAME="SpeakFlow"
APP_PATH="/Applications/${APP_NAME}.app"
PYTHON_BIN="${PYTHON_BIN:-python3}"
OPEN_AFTER_INSTALL=1
CHECK_ONLY=0

usage() {
    cat <<'EOF'
Usage: update-speakflow.sh [--check] [--no-open]

Downloads the latest SpeakFlow DMG from GitHub Releases, replaces the app in
/Applications, ensures mlx-whisper is installed for the active python3, and
reopens the app.

Environment overrides:
  PYTHON_BIN=/path/to/python3   Use a specific Python interpreter
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --check)
            CHECK_ONLY=1
            shift
            ;;
        --no-open)
            OPEN_AFTER_INSTALL=0
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "Missing required command: $1" >&2
        exit 1
    fi
}

require_command curl
require_command hdiutil
require_command xattr
require_command "$PYTHON_BIN"

echo "==> Fetching latest SpeakFlow release metadata..."
release_json="$(curl -fsSL "$API_URL")"

release_info="$(
    RELEASE_JSON="$release_json" "$PYTHON_BIN" - <<'PY'
import json
import os
import sys

payload = json.loads(os.environ["RELEASE_JSON"])
tag = payload.get("tag_name", "")
assets = payload.get("assets", [])
for asset in assets:
    name = asset.get("name", "")
    if name.startswith("SpeakFlow-") and name.endswith(".dmg"):
        print(tag)
        print(name)
        print(asset.get("browser_download_url", ""))
        raise SystemExit(0)

print("Could not find a SpeakFlow DMG asset in the latest release.", file=sys.stderr)
raise SystemExit(1)
PY
)"

latest_tag="$(printf '%s\n' "$release_info" | sed -n '1p')"
asset_name="$(printf '%s\n' "$release_info" | sed -n '2p')"
asset_url="$(printf '%s\n' "$release_info" | sed -n '3p')"

tmp_dir="$(mktemp -d)"
cleanup() {
    if mount | grep -q "$tmp_dir/mount"; then
        hdiutil detach "$tmp_dir/mount" >/dev/null 2>&1 || true
    fi
    rm -rf "$tmp_dir"
}
trap cleanup EXIT

dmg_path="$tmp_dir/$asset_name"
mount_point="$tmp_dir/mount"
mkdir -p "$mount_point"

if [[ "$CHECK_ONLY" -eq 1 ]]; then
    echo
    echo "Latest release: ${latest_tag}"
    echo "DMG asset: ${asset_name}"
    echo "Download URL: ${asset_url}"
    exit 0
fi

echo "==> Downloading ${asset_name} (${latest_tag})..."
curl -fL "$asset_url" -o "$dmg_path"

was_running=0
if pgrep -f "${APP_PATH}/Contents/MacOS/VoiceToTextMac" >/dev/null 2>&1; then
    was_running=1
    echo "==> Stopping running SpeakFlow instance..."
    pkill -f "${APP_PATH}/Contents/MacOS/VoiceToTextMac" || true
    sleep 1
fi

echo "==> Mounting DMG..."
hdiutil attach "$dmg_path" -nobrowse -readonly -mountpoint "$mount_point" >/dev/null

mounted_app="${mount_point}/${APP_NAME}.app"
if [[ ! -d "$mounted_app" ]]; then
    echo "Mounted DMG does not contain ${APP_NAME}.app" >&2
    exit 1
fi

echo "==> Installing ${APP_NAME}.app to /Applications..."
rm -rf "$APP_PATH"
cp -R "$mounted_app" "$APP_PATH"
xattr -cr "$APP_PATH" || true

echo "==> Ensuring mlx-whisper is available via ${PYTHON_BIN}..."
if ! "$PYTHON_BIN" - <<'PY' >/dev/null 2>&1
import mlx_whisper  # noqa: F401
PY
then
    "$PYTHON_BIN" -m pip install --upgrade mlx-whisper
fi

if [[ "$OPEN_AFTER_INSTALL" -eq 1 || "$was_running" -eq 1 ]]; then
    echo "==> Launching ${APP_NAME}..."
    open "$APP_PATH"
fi

echo
echo "Updated ${APP_NAME} to ${latest_tag}."
