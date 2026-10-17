# Changelog

## 0.1.0 — 2026-10-17

- First release: menu bar thermo-hygrometer for Govee H5075/H5072 and ThermoPro TP357/TP357S.
- The menu bar shows the main sensor's temperature and humidity (dimmed when stale).
- The popover has per-sensor cards (battery, 24 h min–max, sparkline) and a combined Swift Charts history with 6H/24H/7D/30D ranges, a temperature/humidity toggle and a hover read-out.
- History backfill from the sensors' onboard memory (up to 20 days) on launch, on wake, every 6 h and on demand, with a 10-minute retry when a sensor doesn't connect.
- Sensors window: add nearby sensors, rename, reorder, set the main sensor, export CSV, remove, and a launch-at-login toggle.
- CLI tools: `--scan`, `--history`, `--dump`, `--snapshot`.
