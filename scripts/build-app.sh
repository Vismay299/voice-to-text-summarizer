#!/usr/bin/env bash
# Build a release .app bundle for VoiceToText.
# Output: dist/VoiceToText.app
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="SpeakFlow"
BUILD_DIR="${REPO_ROOT}/apps/macos/.build/arm64-apple-macosx/release"
APP_OUT="${REPO_ROOT}/dist/${APP_NAME}.app"
CONTENTS="${APP_OUT}/Contents"

echo "==> Cleaning dist/"
rm -rf "${REPO_ROOT}/dist"
mkdir -p "${CONTENTS}/MacOS"
mkdir -p "${CONTENTS}/Resources"

echo "==> Building release binary..."
cd "${REPO_ROOT}/apps/macos"
swift build -c release --product VoiceToTextMac
cd "${REPO_ROOT}"

echo "==> Assembling .app bundle..."

# Binary
cp "${BUILD_DIR}/VoiceToTextMac" "${CONTENTS}/MacOS/VoiceToTextMac"
chmod +x "${CONTENTS}/MacOS/VoiceToTextMac"

# Resources bundle — must sit next to the binary so Bundle.module can find it
cp -r "${BUILD_DIR}/VoiceToTextMac_VoiceToTextMac.bundle" "${CONTENTS}/MacOS/"

# Info.plist
cp "${REPO_ROOT}/apps/macos/Supporting/Info.plist" "${CONTENTS}/Info.plist"

echo "==> Ad-hoc signing..."
# SPM resources bundles ship without an Info.plist, which codesign requires.
# Inject a minimal one so the bundle is signable.
RSBUNDLE="${CONTENTS}/MacOS/VoiceToTextMac_VoiceToTextMac.bundle"
cat > "${RSBUNDLE}/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.speakflow.app.resources</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundlePackageType</key>
    <string>BNDL</string>
</dict>
</plist>
PLIST
codesign --force --deep --sign - "${APP_OUT}"

echo ""
echo "Done: ${APP_OUT}"
echo "Users will need to right-click → Open on first launch (unsigned)."
