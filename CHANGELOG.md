# Changelog

## 0.1.1 — 2026-10-17

- Pick a color per sensor: click its dot in the Sensors window for palette swatches, a custom color, or Reset. The color is used for the card, sparkline and chart line.
- Temperatures show their unit everywhere in the popover: `25.0°C` on the cards, `24h 21.1–25.7°C`, the chart's axis (`24°C`) and its hover read-out.
- Chart grid lines are more visible.
- The last time label on the chart's x axis is no longer clipped. The axis now always spans the whole selected range.
- README shows the dark-mode screenshot only.
- First published release: a tag-triggered GitHub Actions workflow builds a universal (Apple Silicon + Intel) app and attaches `Sensor-Tray-macOS.zip` to the release. The README links straight to the latest download.

## 0.1.0 — 2026-10-17

- First release: menu bar thermo-hygrometer for Govee H5075/H5072 and ThermoPro TP357/TP357S.
- The menu bar shows the main sensor's temperature and humidity (dimmed when stale).
- The popover has per-sensor cards (battery, 24 h min–max, sparkline) and a combined Swift Charts history with 6H/24H/7D/30D ranges, a temperature/humidity toggle and a hover read-out.
- History backfill from the sensors' onboard memory (up to 20 days) on launch, on wake, every 6 h and on demand, with a 10-minute retry when a sensor doesn't connect.
- Sensors window: add nearby sensors, rename, reorder, set the main sensor, export CSV, remove, and a launch-at-login toggle.
- CLI tools: `--scan`, `--history`, `--dump`, `--snapshot`.
