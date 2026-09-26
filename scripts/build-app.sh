#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
xcrun swift build -c release
BIN_DIR="$(xcrun swift build -c release --show-bin-path)"
APP_DIR="$PWD/dist/Serialis.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_DIR/Serialis" "$APP_DIR/Contents/MacOS/Serialis"
cp LICENSE "$APP_DIR/Contents/Resources/LICENSE"
cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Serialis</string>
  <key>CFBundleDisplayName</key><string>Serialis</string>
  <key>CFBundleIdentifier</key><string>com.xplo8e.serialis</string>
  <key>CFBundleExecutable</key><string>Serialis</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP_DIR"
printf 'Built %s\n' "$APP_DIR"
