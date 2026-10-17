# Sensor Tray — design

A macOS menu bar app that shows temperature and humidity from Govee and ThermoPro
Bluetooth LE thermo-hygrometers, replacing the two vendor phone apps.

## Goals

- Menu bar shows the **main** sensor: `22.4° 48%` (°C only).
- Clicking opens a popover with every configured sensor (name, temp, humidity,
  battery, last-seen age, 24h sparkline) and a combined chart (6h / 24h / 7d / 30d).
- Users add, name, rename, remove, reorder sensors and mark one as main.
- History is recorded by the app **and** backfilled from the sensors' onboard memory.
- Launch-at-login toggle, CSV export per sensor.
- Published like `mac-tv-menubar-remote`: GitHub repo, Releases zip, CHANGELOG,
  version bump per change.

Non-goals: alerts, °F, iOS, cloud sync, any model other than the families below.

## Supported devices

| Brand | Models | Live data | History |
|---|---|---|---|
| Govee | H5075 (+ H5072 same format) | advertisement, mfg id `0xEC88`, 6-byte payload | GATT `INTELLI_ROCKS` service, minute records, ~20 days |
| ThermoPro | TP357, TP357S (TP3xx family) | advertisement, name prefix `TP3`, mfg payload | TP357: opcodes `a7` (day/minute) and `a6` (week/hourly). TP357S: `a5` time sync + `cccc`-framed minute records |

### Govee H5075 advertisement

CoreBluetooth `manufacturerData` = `88 EC` + `00 T2 T1 T0 BB 00`.
`v = T2<<16 | T1<<8 | T0`; negative if `v & 0x800000`; `v &= 0x7FFFFF`;
temp = `(v / 1000) / 10` °C (sign applied), humidity = `(v % 1000) / 10` %, battery = `BB` %.
Sample: `88 EC 00 04 18 87 61 00` → 26.8 °C, 42.3 %, 97 %.

### Govee history (from GoveeBTTempLogger)

- Service `494e5445-4c4c-495f-524f-434b535f4857`; characteristics `…2011` (device),
  `…2012` (request), `…2013` (data). Subscribe to notifications on all three.
- Request: write 20 bytes to `…2012`: `33 01 SS SS EE EE 00…00 XX`, where `SSSS` is
  the start as minutes-ago (big-endian), `EEEE = 0001`, and `XX` is the XOR of bytes 0–18.
- Each `…2013` notification: `OO OO` (big-endian minutes-ago of the first record),
  then up to six 3-byte records encoded as in the advertisement. Record *i* is at
  `downloadStartMinute − (offset − i)` minutes. The stream ends when offset ≤ 6.
- Keep-alive: write `aa 01` (padded to 20 bytes with XOR checksum) to `…2012` whenever
  `offset % 450 < 6`.

### ThermoPro TP357 advertisement (from thermopro-ble)

CoreBluetooth `manufacturerData` = 2-byte company id + payload. Indexing that whole buffer
as `d`: temp = `Int16LE(d[1], d[2]) / 10` °C, humidity = `d[3]` %, battery = `d[4] & 3`
(0 → low, 1 → medium, 2 → full). All-`FF` temp/hum → no reading.

### ThermoPro history (from pasky/tp357, tpy357)

- Notify `00010203-0405-0607-0809-0a0b0c0d2b10`, write `…2b11` (without response).
- **TP357 day**: write `a7 00 00 00 00 7a`. Notifications `a7 II II FF` + five 3-byte records
  (`Int16LE temp/10`, `hum`), where `IIII` is a 1-based packet index (LE). 1440 records, oldest
  first; record *k* (0-based) is at `requestMinute − (1439 − k)`. Records with temp `0xFFFF` or
  hum > 100 are skipped. The stream ends on a `0xC2` live-reading notification, after
  288 packets, or after a 30 s idle timeout.
- **TP357 week**: same with `a6 … 6a`, 168 hourly records, record *k* at
  `requestHour − (167 − k)` hours. Used only when the gap is longer than 24 h.
- **TP357S** (name contains `TP357S`): write the time sync
  `a5 YY MM DD hh mm ss DOW cksum`, wait 1 s, then write three commands 200 ms apart:
  `cccc0201000001046666`, `cccc04000000046666`,
  `cccc 01 09 00 00 00 YY MM DD hh mm ss NN NN cksum 6666`. The reassembled stream is
  `cc cc 01 [len×3 LE] 00 [records…] cksum 66 66`, with minute records **most recent first**.

## Architecture

SwiftPM executable (`swift-tools-version 6.0`, Swift 5 language mode, macOS 14),
packaged by `build.sh` into an ad-hoc-signed `LSUIElement` `.app`, the same as the TV remote.

```
Sources/SensorTray/
  Core/                     pure, unit-tested, no CoreBluetooth
    Reading.swift           Reading, Brand, SensorModel, Battery
    GoveeProtocol.swift     advert + history request/packet decode
    ThermoProProtocol.swift advert + history request/packet decode (TP357 + TP357S)
    Store.swift             SQLite (system libsqlite3) readings + sensors tables
    Gaps.swift              gap detection on stored minutes
    CSV.swift               export formatting
  BLE/
    BLEScanner.swift        CBCentralManager, passive scan with duplicates, publishes adverts
    HistoryDownloader.swift connect → discover → run a brand-specific session → disconnect
  App/
    SensorTrayApp.swift     MenuBarExtra(.window), label = main sensor
    AppModel.swift          ObservableObject: sensors, latest readings, sync state
    PopoverView.swift, SensorRow.swift, HistoryChart.swift, SensorsWindow.swift
    LoginItem.swift         SMAppService wrapper
  main.swift                CLI flags (--scan, --history <id>, --dump) else app
Tests/SensorTrayTests/      protocol decoding, store, gaps, CSV
```

### Data flow

1. `BLEScanner` scans continuously (allow duplicates). Each advertisement is parsed by
   `GoveeProtocol` / `ThermoProProtocol` into `(peripheral UUID, name, model, Reading?)`.
2. `AppModel` keeps a `discovered` dict (for the Sensors window) and, for configured
   sensors, the latest reading. Once per minute per sensor it writes to `Store`.
3. `HistorySync` runs at launch, on wake (`NSWorkspace.didWakeNotification`), every 6 h,
   and on manual Sync. For each configured sensor in turn it asks `Store` for the
   oldest gap in the device's retention window (Govee 20 d, TP357 7 d, TP357S 20 d) that
   is longer than 5 min. If there is one, `HistoryDownloader` fetches the range and the
   store upserts it. Failures are logged and shown as a subtle "sync failed" hint, never
   as a modal.

### Storage

`~/Library/Application Support/SensorTray/sensortray.sqlite`

- `sensors(id TEXT PK /*CB UUID*/, name, brand, model, is_main INT, sort INT, added_at)`
- `readings(sensor_id, minute INT /*unix/60*/, temp_c REAL, humidity REAL, source INT,
  PRIMARY KEY(sensor_id, minute))`. Live rows replace backfill rows; backfill uses
  `INSERT OR IGNORE`.
- Charts query with bucketing (`minute / bucket`) so 30 d stays ~720 points per sensor.

### UI

- **Menu bar label**: `thermometer.medium` symbol + `22.4° 48%`, monospaced digits.
  Shows `--` when there's no reading, and is dimmed when the latest reading is older than 10 min.
- **Popover (≈340 pt)**: sensor cards (★ marks main; temp large, humidity, battery
  symbol, "2m ago" when stale, 24h sparkline); a segmented range picker; a Swift Charts
  chart with a temperature/humidity toggle, one color per sensor, and a hover rule with values;
  a footer with Sensors…, Sync (spinner while running), and Quit.
- **Sensors window**: two sections.
  - *Your sensors*: name field, model, star (main), up/down, export CSV, remove.
  - *Nearby*: discovered but unconfigured Govee/ThermoPro devices, with signal bars,
    live reading, and an Add button.
  - Footer: Launch at login toggle.

### Errors

- Bluetooth off or unauthorized → the popover shows a banner explaining it, and the menu bar shows `--`.
- History timeouts: connect 15 s, idle 30 s, overall 120 s, then always cancel the connection.

### Testing

- Unit tests (XCTest via `swift test`) on byte vectors from the reference projects and
  synthesized packets: advert decode, history packet decode/timestamping, request
  encoding and checksums, Store upsert/gap queries, CSV.
- Manual: `--scan` lists both real sensors with readings; `--history <id>` prints the
  downloaded count and time range; the app shows both sensors.

### Release

Repo `nuwanprabhath/sensor-tray`, v0.1.0. Commit locally and ask before push, tag or release.
