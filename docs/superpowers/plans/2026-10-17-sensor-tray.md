# Sensor Tray Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A macOS menu bar app showing live and historical temperature/humidity from Govee H5075 and ThermoPro TP357 BLE sensors.

**Architecture:** A SwiftPM package with three targets. `SensorTrayCore` is a library holding pure protocol decoding, SQLite storage, gap detection and CSV, with no CoreBluetooth or UI. `SensorTray` is the executable: CoreBluetooth scanner and history downloader, a SwiftUI `MenuBarExtra`, and CLI flags. `SensorTrayChecks` is an executable test runner, used because XCTest and swift-testing are unavailable with Command Line Tools only.

**Tech Stack:** Swift 6.4 toolchain (Swift 5 language mode), SwiftUI + Swift Charts (macOS 14), CoreBluetooth, system `libsqlite3`, ServiceManagement (`SMAppService`).

## Global Constraints

- Platform floor macOS 14; `LSUIElement` app; bundle id `com.nuwan.sensor-tray`; app name `Sensor Tray`.
- °C only. Menu bar shows the main sensor only.
- No third-party dependencies.
- Byte formats are exactly as in `docs/superpowers/specs/2026-10-17-sensor-tray-design.md` § Supported devices.
- DB at `~/Library/Application Support/SensorTray/sensortray.sqlite`.
- Version 0.1.0; CHANGELOG entry; commits have no AI attribution; never push or tag without asking.

---

## File structure

```
Package.swift
build.sh, scripts/generate_icon.{sh,swift}
Sources/SensorTrayCore/
  Models.swift            Brand, SensorModel, Battery, Reading, Advert, SensorConfig, HistoryPoint
  GoveeProtocol.swift     parseAdvert, historyRequest(minutesBack:), keepAlive, decodeHistoryPacket
  ThermoProProtocol.swift parseAdvert, dayRequest/weekRequest, decodeLegacyPacket, timeSync/sRequests, decodeSStream
  Store.swift             SQLite wrapper: sensors CRUD, upsert readings, latest, series(bucketed), oldestGap
  CSV.swift               csv(for points:name:)
Sources/SensorTray/
  BLEScanner.swift        CBCentralManager delegate → Advert stream
  HistoryDownloader.swift per-brand GATT sessions → [HistoryPoint]
  HistorySync.swift       schedules gap backfill
  AppModel.swift          state + persistence glue
  SensorTrayApp.swift     MenuBarExtra + Window("Sensors")
  PopoverView.swift, SensorCard.swift, HistoryChart.swift, SensorsView.swift, Sparkline.swift
  LoginItem.swift
  main.swift              CLI: --scan, --history <uuid>, --dump
Sources/SensorTrayChecks/main.swift   assertion runner
```

## Interfaces (shared by all tasks)

```swift
public enum Brand: String, Codable { case govee, thermopro }
public enum SensorModel: String, Codable { case h5075, tp357, tp357s
  public var brand: Brand; public var historyRetentionMinutes: Int /* 28800, 10080, 28800 */ }
public struct Reading: Equatable { public var tempC: Double; public var humidity: Double; public var battery: Int? /*0-100*/ }
public struct Advert { public var id: UUID; public var name: String; public var model: SensorModel; public var reading: Reading?; public var rssi: Int }
public struct HistoryPoint: Equatable { public var minute: Int /*unix/60*/; public var tempC: Double; public var humidity: Double }
public struct SensorConfig: Identifiable, Equatable { public var id: UUID; public var name: String; public var model: SensorModel; public var isMain: Bool; public var sort: Int }

enum GoveeProtocol {
  static func model(forName: String) -> SensorModel?          // "GVH5075_xxxx", "GVH5072_xxxx"
  static func parseAdvert(manufacturerData: [UInt8]) -> Reading?
  static func historyRequest(minutesBack: Int) -> [UInt8]       // 20 bytes
  static func keepAlive() -> [UInt8]                            // 20 bytes
  static func decodeHistoryPacket(_ p: [UInt8], downloadMinute: Int) -> (offset: Int, points: [HistoryPoint])
}
enum ThermoProProtocol {
  static func model(forName: String) -> SensorModel?          // "TP357S (..)" → .tp357s, "TP3.." → .tp357
  static func parseAdvert(manufacturerData: [UInt8]) -> Reading?
  static let dayRequest: [UInt8], weekRequest: [UInt8]
  static func decodeLegacyPackets(_ ps: [[UInt8]], opcode: UInt8, requestMinute: Int, stepMinutes: Int, total: Int) -> [HistoryPoint]
  static func timeSync(_ d: Date, calendar: Calendar) -> [UInt8]
  static func sHistoryRequests(_ d: Date, count: Int, calendar: Calendar) -> [[UInt8]]
  static func decodeSStream(_ buf: [UInt8], requestMinute: Int) throws -> [HistoryPoint]
}
final class Store {
  init(path: String) throws
  func sensors() -> [SensorConfig]; func save(_ s: SensorConfig); func delete(id: UUID); func setMain(id: UUID)
  func insertLive(_ id: UUID, minute: Int, reading: Reading)
  func insertBackfill(_ id: UUID, points: [HistoryPoint])
  func series(_ id: UUID, from: Int, to: Int, bucketMinutes: Int) -> [HistoryPoint]
  func lastMinute(_ id: UUID) -> Int?
  func oldestGapStart(_ id: UUID, now: Int, windowMinutes: Int, minGap: Int) -> Int?  // minute where backfill should start
}
enum CSV { static func render(_ points: [HistoryPoint], sensorName: String) -> String }
```

### Task 1: Package skeleton + check runner
- [ ] `Package.swift` with the three targets, linking `sqlite3` in Core (`linkerSettings: [.linkedLibrary("sqlite3")]`).
- [ ] `SensorTrayChecks/main.swift` with `check(_ cond:, _ msg:)`; counts failures and calls `exit(1)` if there are any.
- [ ] `swift build` succeeds. Commit.

### Task 2: Models + Govee protocol (TDD)
Checks:
- `parseAdvert([0x88,0xEC,0x00,0x04,0x18,0x87,0x61,0x00])` → 26.8 °C, 42.3 %, battery 97.
- Negative: value `0x80 | 0x01, 0x86, 0xA0` (100000 → -10.0 °C, 0.0 %) → -10.0.
- Wrong company id or length → nil.
- `historyRequest(minutesBack: 0x0123)`: bytes `33 01 01 23 00 01`, zeros, and the last byte is the XOR of the first 19; length 20.
- `decodeHistoryPacket`: offset 10, two records, then `FF FF FF` padding → points at minutes `dm-10`, `dm-9`. Padding (`0xFFFFFF`) is skipped.
- `model(forName:)`: "GVH5075_BCAE" → .h5075; "Foo" → nil.

### Task 3: ThermoPro protocol (TDD)
Checks:
- `parseAdvert([0xC2,0xE1,0x00,0x2D,0x02,0x00])` → 22.5 °C, 45 %, battery 100. `d[4]&3`: 1 → 50, 0 → 10.
- All-FF payload → nil. Negative `0x9C,0xFF` → -10.0.
- `decodeLegacyPackets`: two packets (indexes 1, 2) of five records each, total 1440 → first record's minute is `rm-1439`, packet 2 record 0 is `rm-1434`; `FF FF` records are skipped; packets with a wrong opcode are ignored.
- `decodeSStream`: a synthesized stream with two records (most recent first) and a valid length and checksum → points `rm`, `rm-1`; a bad checksum throws.
- `timeSync` for 2026-10-17 13:05:09 → `a5 1a 0a 11 0d 05 09 06 <sum&ff>` (Saturday weekday()+1 = 6).

### Task 4: Store + CSV (TDD, temp file DB)
Checks:
- Save, reload, `setMain`: the main sensor is unique.
- `insertBackfill` then `insertLive` for the same minute → the live value wins; a later backfill doesn't overwrite it.
- `series` bucketing averages.
- `oldestGapStart`: data at minutes 0..100 and 200..300, now 300, window 1000, minGap 5 → returns the earliest missing minute in the window, clamped to `now - window` (here `now - window` < 0, so the gap before minute 0 counts → -700). With data from `now - window` onward and a hole at 101..199 → 101. Fully covered → nil.
- CSV header `timestamp,sensor,temperature_c,humidity_pct` with ISO-8601 timestamps.

### Task 5: BLE scanner + CLI `--scan`
- `BLEScanner: NSObject, CBCentralManagerDelegate`. Scans with `AllowDuplicates`, uses `onAdvert: (Advert) -> Void`, and has `state` published via callback.
- The model is resolved from the local name (`CBAdvertisementDataLocalNameKey`, falling back to `peripheral.name`), then the brand parser runs.
- `--scan [seconds]` prints `UUID  name  model  temp hum batt rssi`. Verify against the real sensors.

### Task 6: History downloader + CLI `--history <uuid>`
- An async `download(id:model:minutesBack:) async throws -> [HistoryPoint]` that retrieves the peripheral (`retrievePeripherals(withIdentifiers:)`), connects with a 15 s timeout, discovers the services/characteristics, then:
  - Govee: notify on 2011/2012/2013, write the request to 2012, collect 2013 packets, send keep-alive, finish at offset ≤ 6.
  - TP357: notify 2b10, write `dayRequest` (and `weekRequest` if minutesBack > 1440) to 2b11, collect until a `0xC2` packet, the expected count, or 30 s idle.
  - TP357S: time sync, then the three requests, reassembling until `66 66`.
- 120 s overall deadline; always `cancelPeripheralConnection`.
- Verify with `--history` on both real sensors.

### Task 7: App model, sync, persistence
- `AppModel` (`@MainActor ObservableObject`): `sensors`, `latest[UUID]: (Reading, Date)`, `nearby[UUID]: Advert`, `syncing`, `lastSyncError`, `btState`.
- Writes live readings once per minute per sensor. Sensors persist via Store.
- `HistorySync` runs on launch, on wake, every 6 h, and on manual sync. Sensors are handled sequentially, using `oldestGapStart` with the model's retention and a 5 min minimum gap.

### Task 8: UI
- `MenuBarExtra` label is `thermometer.medium` + `22.4° 48%`, dimmed when stale.
- Popover: banner, sensor cards with sparkline, range picker, temp/humidity toggle, chart with hover, footer.
- `Window("Sensors")`: your sensors (rename, star, reorder, export CSV, remove), nearby (Add), launch at login.
- `NSApp.activate` when opening the window.

### Task 9: Packaging, icon, docs, release prep
- `build.sh` (Info.plist with `NSBluetoothAlwaysUsageDescription`), an icon script, README, CHANGELOG 0.1.0, and a screenshot.
- Build the app, run it, verify it against the real devices, and commit. Then ask the user about creating the GitHub repo and the release.
