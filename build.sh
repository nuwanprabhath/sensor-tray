#!/bin/bash
# Builds the release binary and assembles "Sensor Tray.app" in dist/.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Sensor Tray"
BUNDLE_ID="com.nuwan.sensor-tray"
VERSION="0.1.0"
BUILD_NUMBER="1"
DIST="dist/$APP_NAME.app"

swift build -c release --product SensorTray

rm -rf "$DIST"
mkdir -p "$DIST/Contents/MacOS" "$DIST/Contents/Resources"

cp ".build/release/SensorTray" "$DIST/Contents/MacOS/SensorTray"

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
    <key>NSBluetoothAlwaysUsageDescription</key>
    <string>Sensor Tray reads temperature and humidity from your Govee and ThermoPro sensors over Bluetooth.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$DIST"

echo "Built: $DIST"
echo "Run:   open \"$DIST\""
echo "Install: cp -R \"$DIST\" /Applications/"
