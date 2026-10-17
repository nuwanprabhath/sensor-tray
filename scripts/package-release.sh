#!/bin/bash
# Builds "Sensor Tray.app" and zips it for a GitHub release:
#   dist/Sensor-Tray-macOS.zip   (stable name, so README can link to releases/latest/download/…)
# Pass --universal for an arm64 + x86_64 build (requires full Xcode, as on CI).
set -euo pipefail
cd "$(dirname "$0")/.."

./build.sh "$@"

ZIP="dist/Sensor-Tray-macOS.zip"
rm -f "$ZIP"
# ditto keeps the bundle's symlinks, permissions and code signature intact.
ditto -c -k --keepParent "dist/Sensor Tray.app" "$ZIP"
echo "Packaged: $ZIP ($(du -h "$ZIP" | cut -f1))"
