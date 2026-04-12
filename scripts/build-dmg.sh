#!/usr/bin/env bash
# Package dist/VoiceToText.app into a distributable .dmg.
# Run build-app.sh first.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="SpeakFlow"
APP_PATH="${REPO_ROOT}/dist/${APP_NAME}.app"
DIST_DIR="${REPO_ROOT}/dist"

if [ ! -d "${APP_PATH}" ]; then
    echo "Error: ${APP_PATH} not found. Run scripts/build-app.sh first."
    exit 1
fi

VERSION=$(defaults read "${APP_PATH}/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "0.1.0")
DMG_NAME="${APP_NAME}-${VERSION}.dmg"
DMG_PATH="${DIST_DIR}/${DMG_NAME}"

echo "==> Creating ${DMG_NAME}..."

TMP_DIR=$(mktemp -d)
cp -r "${APP_PATH}" "${TMP_DIR}/"
ln -s /Applications "${TMP_DIR}/Applications"

hdiutil create \
    -volname "${APP_NAME}" \
    -srcfolder "${TMP_DIR}" \
    -ov \
    -format UDZO \
    "${DMG_PATH}"

rm -rf "${TMP_DIR}"

echo ""
echo "Done: ${DMG_PATH}"
echo "Upload this file to your GitHub Release."
