#!/bin/bash
# Builds the release binary and assembles "Sensor Tray.app" in dist/.
#   ./build.sh              native arch (fast, for local use)
#   ./build.sh --universal  arm64 + x86_64 (needs full Xcode; used by the release workflow)
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Sensor Tray"
BUNDLE_ID="com.nuwan.sensor-tray"
VERSION="$(cat VERSION)"
# Monotonic build number for CFBundleVersion: commit count (falls back to 1 outside git).
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
DIST="dist/$APP_NAME.app"

if [ "${1:-}" = "--universal" ]; then
    swift build -c release --product SensorTray --arch arm64 --arch x86_64
    BINARY=".build/apple/Products/Release/SensorTray"
else
    swift build -c release --product SensorTray
    BINARY=".build/release/SensorTray"
fi

rm -rf "$DIST"
mkdir -p "$DIST/Contents/MacOS" "$DIST/Contents/Resources"

cp "$BINARY" "$DIST/Contents/MacOS/SensorTray"

if [ ! -f "AppIcon.icns" ]; then
    ./scripts/generate_icon.sh
fi
cp "AppIcon.icns" "$DIST/Contents/Resources/AppIcon.icns"

cat > "$DIST/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>SensorTray</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSLocalNetworkUsageDescription</key>
    <string>Sensor Tray finds your Philips air purifier on the local network and reads its air quality.</string>
    <key>NSBluetoothAlwaysUsageDescription</key>
    <string>Sensor Tray reads temperature and humidity from your Govee and ThermoPro sensors over Bluetooth.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$DIST"

echo "Built: $DIST"
echo "Run:   open \"$DIST\""
echo "Install: cp -R \"$DIST\" /Applications/"
