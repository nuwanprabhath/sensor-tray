#!/bin/bash
# Draws AppIcon.icns from scratch (no external image assets) via CoreGraphics.
set -euo pipefail
cd "$(dirname "$0")/.."

ICONSET="AppIcon.iconset"
rm -rf "$ICONSET"

swift scripts/generate_icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o AppIcon.icns
rm -rf "$ICONSET"

echo "Built: AppIcon.icns"
