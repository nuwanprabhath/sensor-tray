import Darwin
import Foundation
import SensorTrayCore
import SQLite3

// Minimal assertion runner: XCTest / swift-testing need a full Xcode install,
// so `swift run SensorTrayChecks` stands in for `swift test`.
var failures = 0
var passed = 0

func check(_ condition: @autoclosure () -> Bool, _ message: String, file: String = #fileID, line: Int = #line) {
    if condition() {
        passed += 1
    } else {
        failures += 1
        print("FAIL \(file):\(line) \(message)")
    }
}

func near(_ a: Double?, _ b: Double, _ tolerance: Double = 0.001) -> Bool {
    guard let a else { return false }
    return abs(a - b) < tolerance
}

func xor(_ bytes: ArraySlice<UInt8>) -> UInt8 { bytes.reduce(0, ^) }

func hex(_ string: String) -> [UInt8] {
    var bytes: [UInt8] = []
    var index = string.startIndex
    while index < string.endIndex {
        let next = string.index(index, offsetBy: 2)
        bytes.append(UInt8(string[index..<next], radix: 16)!)
        index = next
    }
    return bytes
}


func removeDatabase(_ path: String) {
    for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
}

func databaseBytes(_ path: String) -> Int {
    ["", "-wal"].reduce(0) { total, suffix in
        total + ((try? FileManager.default.attributesOfItem(atPath: path + suffix)[.size] as? Int) ?? 0)
    }
}

func residentMB() -> Double {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : 0
}

// MARK: - Govee

do {
    let r = GoveeProtocol.parseAdvert(manufacturerData: [0x88, 0xEC, 0x00, 0x04, 0x18, 0x87, 0x61, 0x00])
    check(near(r?.tempC, 26.8), "govee advert temp \(String(describing: r))")
    check(near(r?.humidity, 42.3), "govee advert humidity")
    check(r?.battery == 97, "govee advert battery")

    // 0x8186A0 → sign bit + 100000 → -10.0 °C, 0.0 %
    let neg = GoveeProtocol.parseAdvert(manufacturerData: [0x88, 0xEC, 0x00, 0x81, 0x86, 0xA0, 0x64, 0x00])
    check(near(neg?.tempC, -10.0), "govee negative temp \(String(describing: neg))")

    check(GoveeProtocol.parseAdvert(manufacturerData: [0x4C, 0x00, 0x00, 0x04, 0x18, 0x87, 0x61, 0x00]) == nil, "govee wrong company")
    check(GoveeProtocol.parseAdvert(manufacturerData: [0x88, 0xEC, 0x00, 0x04, 0x18]) == nil, "govee short payload")

    // Real capture: Govee record + iBeacon record, concatenated by CoreBluetooth.
    let combined = hex("88ec0003d6e33e004c000215494e54454c4c495f524f434b535f48575075f2ffc2")
    let c = GoveeProtocol.parseAdvert(manufacturerData: combined)
    check(near(c?.tempC, 25.1) && near(c?.humidity, 61.9) && c?.battery == 62, "govee combined records \(String(describing: c))")
    let reversed = hex("4c000215494e54454c4c495f524f434b535f48575075f2ffc2") + hex("88ec0003d6e33e00")
    check(near(GoveeProtocol.parseAdvert(manufacturerData: reversed)?.tempC, 25.1), "govee combined records, iBeacon first")
    check(GoveeProtocol.parseAdvert(manufacturerData: hex("4c000215494e54454c4c495f524f434b535f48575075f2ffc2")) == nil, "govee iBeacon only")

    let req = GoveeProtocol.historyRequest(minutesBack: 0x0123)
    check(req.count == 20, "govee request length")
    check(Array(req[0..<6]) == [0x33, 0x01, 0x01, 0x23, 0x00, 0x01], "govee request header \(req)")
    check(req[19] == xor(req[0..<19]), "govee request checksum")
    check(req[6..<19].allSatisfy { $0 == 0 }, "govee request padding")

    let keepAlive = GoveeProtocol.keepAlive()
    check(keepAlive.count == 20 && keepAlive[0] == 0xAA && keepAlive[1] == 0x01 && keepAlive[19] == 0xAB, "govee keep-alive")

    // offset 10, two records (26.8/42.3 and 21.7/50.2), rest padding
    var packet: [UInt8] = [0x00, 0x0A, 0x04, 0x18, 0x87, 0x03, 0x51, 0x9E]
    packet += Array(repeating: 0xFF, count: 12)
    let decoded = GoveeProtocol.decodeHistoryPacket(packet, downloadMinute: 1000)
    check(decoded.offset == 10, "govee packet offset")
    check(decoded.points.count == 2, "govee packet count \(decoded.points)")
    check(decoded.points.first?.minute == 990, "govee packet first minute")
    check(decoded.points.last?.minute == 991, "govee packet second minute")
    check(near(decoded.points.last?.tempC, 21.7) && near(decoded.points.last?.humidity, 50.2), "govee packet second values")

    check(GoveeProtocol.model(forName: "GVH5075_BCAE") == .h5075, "govee name H5075")
    check(GoveeProtocol.model(forName: "GVH5072_1234") == .h5075, "govee name H5072")
    check(GoveeProtocol.model(forName: "Foo") == nil, "govee name unknown")
    check(GoveeProtocol.model(forManufacturerData: [0x88, 0xEC, 0x00, 0x04, 0x18, 0x87, 0x61, 0x00]) == .h5075, "govee model from mfg data")
    check(GoveeProtocol.model(forManufacturerData: [0xC2, 0xE1, 0x00, 0x2D, 0x02, 0x00]) == nil, "govee model rejects thermopro")
}

// MARK: - ThermoPro

do {
    let r = ThermoProProtocol.parseAdvert(manufacturerData: [0xC2, 0xE1, 0x00, 0x2D, 0x02, 0x00])
    check(near(r?.tempC, 22.5), "tp advert temp \(String(describing: r))")
    check(near(r?.humidity, 45), "tp advert humidity")
    check(r?.battery == 100, "tp advert battery full")
    check(ThermoProProtocol.parseAdvert(manufacturerData: [0xC2, 0xE1, 0x00, 0x2D, 0x01, 0x00])?.battery == 50, "tp battery mid")
    check(ThermoProProtocol.parseAdvert(manufacturerData: [0xC2, 0xE1, 0x00, 0x2D, 0x00, 0x00])?.battery == 10, "tp battery low")
    check(ThermoProProtocol.parseAdvert(manufacturerData: [0xC2, 0xFF, 0xFF, 0xFF, 0x02, 0x00]) == nil, "tp all-FF")
    let tpCapture = ThermoProProtocol.parseAdvert(manufacturerData: hex("c206012c220b01"))  // real TP357S capture
    check(near(tpCapture?.tempC, 26.2) && near(tpCapture?.humidity, 44) && tpCapture?.battery == 100, "tp real capture \(String(describing: tpCapture))")
    check(near(ThermoProProtocol.parseAdvert(manufacturerData: [0xC2, 0x9C, 0xFF, 0x2D, 0x02, 0x00])?.tempC, -10.0), "tp negative")

    check(ThermoProProtocol.model(forName: "TP357 (7216)") == .tp357, "tp name TP357")
    check(ThermoProProtocol.model(forName: "TP357S (ABCD)") == .tp357s, "tp name TP357S")
    check(ThermoProProtocol.model(forName: "GVH5075_1") == nil, "tp name unknown")

    check(ThermoProProtocol.dayRequest == [0xA7, 0x00, 0x00, 0x00, 0x00, 0x7A], "tp day request")
    check(ThermoProProtocol.weekRequest == [0xA6, 0x00, 0x00, 0x00, 0x00, 0x6A], "tp week request")

    func legacyPacket(_ index: UInt16, _ records: [(Int16, UInt8)]) -> [UInt8] {
        var p: [UInt8] = [0xA7, UInt8(index & 0xFF), UInt8(index >> 8), 0x00]
        for (t, h) in records {
            let u = UInt16(bitPattern: t)
            p += [UInt8(u & 0xFF), UInt8(u >> 8), h]
        }
        return p
    }
    let p1 = legacyPacket(1, [(225, 45), (226, 46), (-1, 0xFF), (227, 47), (228, 48)])
    let p2 = legacyPacket(2, [(230, 50), (231, 51), (232, 52), (233, 53), (234, 54)])
    let noise: [UInt8] = [0xC2, 0xE1, 0x00, 0x2D, 0x02, 0x00, 0x00]
    let points = ThermoProProtocol.decodeLegacyPackets([p1, noise, p2], opcode: 0xA7, requestMinute: 10_000, stepMinutes: 1, total: 1440)
    check(points.count == 9, "tp legacy count \(points.count)")
    check(points.first?.minute == 10_000 - 1439, "tp legacy first minute")
    check(near(points.first?.tempC, 22.5) && near(points.first?.humidity, 45), "tp legacy first values")
    check(points.first(where: { near($0.tempC, 23.0) })?.minute == 10_000 - 1434, "tp legacy packet 2 minute")

    // TP357S stream: cc cc 01 [len x3 LE] 00 [records] cksum 66 66, most recent first
    let records: [UInt8] = [0xE1, 0x00, 0x2D, 0xE6, 0x00, 0x32]   // 22.5/45 (now), 23.0/50 (now-1)
    let length = records.count + 1
    var inner: [UInt8] = [0x01, UInt8(length & 0xFF), UInt8((length >> 8) & 0xFF), UInt8((length >> 16) & 0xFF), 0x00] + records
    inner.append(UInt8(inner.reduce(0) { ($0 + Int($1)) } & 0xFF))
    let stream: [UInt8] = [0xCC, 0xCC] + inner + [0x66, 0x66]
    let sPoints = (try? ThermoProProtocol.decodeSStream(stream, requestMinute: 500)) ?? []
    check(sPoints.count == 2, "tp357s count")
    check(sPoints.first(where: { $0.minute == 500 }).map { near($0.tempC, 22.5) } == true, "tp357s newest at request minute")
    check(sPoints.first(where: { $0.minute == 499 }).map { near($0.humidity, 50) } == true, "tp357s older one minute back")
    var corrupt = stream
    corrupt[corrupt.count - 3] ^= 0x01
    check((try? ThermoProProtocol.decodeSStream(corrupt, requestMinute: 500)) == nil, "tp357s bad checksum throws")

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let date = calendar.date(from: DateComponents(year: 2026, month: 10, day: 17, hour: 13, minute: 5, second: 9))!
    let sync = ThermoProProtocol.timeSync(date, calendar: calendar)
    let syncBody: [UInt8] = [0xA5, 26, 10, 17, 13, 5, 9, 6]
    check(sync == syncBody + [UInt8(syncBody.reduce(0) { $0 + Int($1) } & 0xFF)], "tp357s time sync \(sync)")
    let sReqs = ThermoProProtocol.sHistoryRequests(date, count: 1440, calendar: calendar)
    check(sReqs.count == 3 && sReqs[0] == [0xCC, 0xCC, 0x02, 0x01, 0x00, 0x00, 0x01, 0x04, 0x66, 0x66], "tp357s session init")
    check(sReqs[2].count == 18 && sReqs[2][13] == 0xA0 && sReqs[2][14] == 0x05, "tp357s count bytes \(sReqs[2])")
}

// MARK: - Store

do {
    let path = NSTemporaryDirectory() + "sensortray-checks-\(UUID().uuidString).sqlite"
    defer { try? FileManager.default.removeItem(atPath: path) }
    let store = try Store(path: path)
    let a = UUID(), b = UUID()
    store.save(SensorConfig(id: a, name: "Living room", model: .h5075, isMain: true, sort: 0))
    store.save(SensorConfig(id: b, name: "Bedroom", model: .tp357, isMain: false, sort: 1))
    check(store.sensors().map(\.name) == ["Living room", "Bedroom"], "store sensors order")
    store.setMain(id: b)
    check(store.sensors().filter(\.isMain).map(\.id) == [b], "store unique main")
    var renamed = store.sensors()[0]
    renamed.name = "Lounge"
    store.save(renamed)
    check(store.sensors()[0].name == "Lounge", "store rename")
    check(store.sensors()[0].colorHex == nil, "store default color")
    store.setColor(id: a, hex: "#FF8800")
    check(store.sensors()[0].colorHex == "#FF8800", "store color set")
    var recolored = store.sensors()[0]
    recolored.name = "Lounge 2"
    store.save(recolored)
    check(store.sensors()[0].colorHex == "#FF8800", "store save keeps color")
    store.setColor(id: a, hex: nil)
    check(store.sensors()[0].colorHex == nil, "store color reset")

    store.insertBackfill(a, points: [HistoryPoint(minute: 100, tempC: 20, humidity: 40)])
    store.insertLive(a, minute: 100, reading: Reading(tempC: 21, humidity: 41, battery: nil))
    store.insertBackfill(a, points: [HistoryPoint(minute: 100, tempC: 19, humidity: 39)])
    check(store.series(a, from: 0, to: 1000, bucketMinutes: 1) == [HistoryPoint(minute: 100, tempC: 21, humidity: 41)], "store live wins over backfill")

    store.insertLive(a, minute: 101, reading: Reading(tempC: 23, humidity: 43, battery: nil))
    let bucketed = store.series(a, from: 0, to: 1000, bucketMinutes: 10)
    check(bucketed.count == 1 && near(bucketed.first?.tempC, 22) && bucketed.first?.minute == 100, "store bucketing \(bucketed)")
    check(store.lastMinute(a) == 101, "store last minute")

    // Gap detection
    let c = UUID()
    store.save(SensorConfig(id: c, name: "Gaps", model: .h5075, isMain: false, sort: 2))
    check(store.oldestGapStart(c, now: 300, windowMinutes: 100, minGap: 5) == 200, "gap: empty sensor → whole window")
    store.insertBackfill(c, points: (0...100).map { HistoryPoint(minute: $0, tempC: 20, humidity: 40) })
    store.insertBackfill(c, points: (200...300).map { HistoryPoint(minute: $0, tempC: 20, humidity: 40) })
    check(store.oldestGapStart(c, now: 300, windowMinutes: 1000, minGap: 5) == -700, "gap: before first reading")
    check(store.oldestGapStart(c, now: 300, windowMinutes: 300, minGap: 5) == 101, "gap: interior hole")
    check(store.oldestGapStart(c, now: 300, windowMinutes: 50, minGap: 5) == nil, "gap: fully covered")
    check(store.oldestGapStart(c, now: 303, windowMinutes: 50, minGap: 5) == nil, "gap: tiny tail ignored")
    check(store.oldestGapStart(c, now: 320, windowMinutes: 50, minGap: 5) == 301, "gap: tail after last reading")
    store.setSyncedThrough(c, minute: 250)
    check(store.oldestGapStart(c, now: 300, windowMinutes: 300, minGap: 5) == nil, "gap: synced-through skips old holes")

    store.delete(id: c)
    check(store.series(c, from: 0, to: 1000, bucketMinutes: 1).isEmpty, "store delete removes readings")
    check(!store.sensors().contains { $0.id == c }, "store delete removes sensor")
}

// MARK: - Schema v1 → v2 migration

do {
    let path = NSTemporaryDirectory() + "sensortray-v1-\(UUID().uuidString).sqlite"
    defer { removeDatabase(path) }
    let a = UUID(), b = UUID()
    // A database exactly as 0.1.x wrote it.
    var db: OpaquePointer?
    sqlite3_open(path, &db)
    sqlite3_exec(db, """
        CREATE TABLE sensors(id TEXT PRIMARY KEY, name TEXT NOT NULL, model TEXT NOT NULL,
            is_main INTEGER NOT NULL DEFAULT 0, sort INTEGER NOT NULL DEFAULT 0,
            synced_through INTEGER, added_at INTEGER NOT NULL, color TEXT);
        CREATE TABLE readings(sensor_id TEXT NOT NULL, minute INTEGER NOT NULL, temp_c REAL NOT NULL,
            humidity REAL NOT NULL, source INTEGER NOT NULL, PRIMARY KEY(sensor_id, minute)) WITHOUT ROWID;
        INSERT INTO sensors VALUES('\(a.uuidString)', 'Living room', 'h5075', 1, 0, 500, 1, '#FF8800');
        INSERT INTO sensors VALUES('\(b.uuidString)', 'Bedroom', 'tp357s', 0, 1, NULL, 2, NULL);
        INSERT INTO readings VALUES('\(a.uuidString)', 120, 25.1, 61.9, 0);
        INSERT INTO readings VALUES('\(a.uuidString)', 121, 25.3, 62.1, 1);
        INSERT INTO readings VALUES('\(a.uuidString)', 180, 20.0, 50.0, 1);
        INSERT INTO readings VALUES('\(b.uuidString)', 120, -3.4, 41.0, 1);
        """, nil, nil, nil)
    sqlite3_close(db)

    let store = try Store(path: path)
    check(store.userVersion == Store.schemaVersion, "migration sets user_version")
    let sensors = store.sensors()
    check(sensors.map(\.name) == ["Living room", "Bedroom"], "migration keeps sensors \(sensors.map(\.name))")
    check(sensors.first?.colorHex == "#FF8800" && sensors.first?.isMain == true, "migration keeps color and main")
    let raw = store.series(a, from: 0, to: 1000, bucketMinutes: 1)
    check(raw.count == 3 && near(raw.first?.tempC, 25.1) && near(raw.first?.humidity, 61.9), "migration keeps readings \(raw)")
    check(near(store.series(b, from: 0, to: 1000, bucketMinutes: 1).first?.tempC, -3.4), "migration negative temps")
    check(store.oldestGapStart(a, now: 600, windowMinutes: 1000, minGap: 5) == 500, "migration keeps synced_through")
    let hours = store.aggregate(a, from: 0, to: 1000, bucketMinutes: 60)
    check(hours.count == 2 && hours.first?.count == 2 && near(hours.first?.tempAvg, 25.2), "migration builds hourly rollup \(hours)")

    // Reopening an already-migrated database is a no-op.
    let reopened = try Store(path: path)
    check(reopened.series(a, from: 0, to: 1000, bucketMinutes: 1).count == 3, "migration idempotent")
}

// MARK: - Aggregates and the hourly rollup

do {
    let path = NSTemporaryDirectory() + "sensortray-agg-\(UUID().uuidString).sqlite"
    defer { removeDatabase(path) }
    let store = try Store(path: path)
    let s = UUID()
    store.save(SensorConfig(id: s, name: "S", model: .h5075, isMain: true, sort: 0))
    // Two hours of minute data: temp rises 0.1 °C a minute from 20.0, humidity fixed.
    let base = 1_000_080 // a whole two hours (÷120)
    store.insertBackfill(s, points: (0..<120).map { HistoryPoint(minute: base + $0, tempC: 20 + Double($0) / 10, humidity: 50) })

    let fine = store.aggregate(s, from: base, to: base + 119, bucketMinutes: 30)
    check(fine.count == 4 && fine.allSatisfy { $0.count == 30 }, "aggregate 30-min buckets \(fine.map(\.count))")
    check(near(fine[0].tempMin, 20.0) && near(fine[0].tempMax, 22.9) && near(fine[0].tempAvg, 21.45), "aggregate min/max/avg")

    let hourly = store.aggregate(s, from: base, to: base + 119, bucketMinutes: 60)
    check(hourly.count == 2 && near(hourly[1].tempAvg, 28.95) && near(hourly[1].tempMax, 31.9), "aggregate from rollup \(hourly)")
    let twoHours = store.aggregate(s, from: base, to: base + 119, bucketMinutes: 120)
    check(twoHours.count == 1 && twoHours[0].count == 120 && near(twoHours[0].tempAvg, 25.95), "rollup weighted average")

    // A live reading replaces the backfilled minute and the rollup follows.
    store.insertLive(s, minute: base, reading: Reading(tempC: 30, humidity: 50, battery: nil))
    let afterLive = store.aggregate(s, from: base, to: base + 59, bucketMinutes: 60)
    check(near(afterLive.first?.tempMax, 30) && afterLive.first?.count == 60, "rollup tracks live override \(afterLive)")
    // …and a later backfill of that minute doesn't undo it.
    store.insertBackfill(s, points: [HistoryPoint(minute: base, tempC: 10, humidity: 50)])
    check(near(store.aggregate(s, from: base, to: base + 59, bucketMinutes: 60).first?.tempMin, 20.1), "backfill never overrides live")

    // Day buckets align to the given UTC offset (e.g. +10:30 → rounded to +10:00 on the rollup).
    let day = store.aggregate(s, from: base, to: base + 119, bucketMinutes: 1440, alignOffset: 630)
    check(day.count == 1 && (day[0].minute + 600) % 1440 == 0, "day bucket aligned to local midnight \(day)")

    check(store.firstMinute(s) == base && store.lastMinute(s) == base + 119, "first/last minute")
    check(store.earliestMinute() == base, "earliest minute across sensors")
    check(store.sampleCount(s) == 120, "sample count")

    // The read-only connection sees the writer's data.
    let reader = try Store(path: path, readOnly: true)
    check(reader.aggregate(s, from: base, to: base + 119, bucketMinutes: 60).count == 2, "read-only connection reads")
}

// MARK: - Chart window maths

do {
    let now = 10_000_000
    let earliest = now - 400 * 1440 // ~13 months of history

    let live = ChartWindow(range: .day)
    check(live.isLive && live.span(now: now, earliest: earliest) == (now - 1440)...now, "live day span")
    check(!live.canPanForward(now: now) && live.canPanBack(now: now, earliest: earliest), "live: back only")

    let back = live.panned(by: -1440, now: now, earliest: earliest)
    check(back.end == now - 1440 && back.canPanForward(now: now), "pan back one day")
    check(back.panned(by: 1440, now: now, earliest: earliest).isLive, "pan forward returns to live")
    check(back.panned(by: 99_999, now: now, earliest: earliest).isLive, "pan past now clamps to live")

    let farBack = live.panned(by: -10 * 365 * 1440, now: now, earliest: earliest)
    check(farBack.end == earliest + 1440, "pan clamps at first reading \(String(describing: farBack.end))")
    check(!farBack.canPanBack(now: now, earliest: earliest), "can't pan before history")

    let year = ChartWindow(range: .year)
    check(year.bucketMinutes(now: now, earliest: earliest) == 1440 && year.showsBand(now: now, earliest: earliest), "year: daily buckets with band")
    check(!ChartWindow(range: .week).showsBand(now: now, earliest: earliest), "week: no band")

    // Not enough history to pan a whole year.
    check(year.panned(by: -1440, now: now, earliest: now - 100 * 1440).isLive, "short history keeps year live")

    let all = ChartWindow(range: .all)
    check(all.span(now: now, earliest: earliest) == earliest...now, "all spans history")
    check(all.bucketMinutes(now: now, earliest: earliest) == 1440, "all: daily buckets for 400 days")
    check(all.bucketMinutes(now: now, earliest: now - 600 * 1440) == 2 * 1440, "all: 2-day buckets for 600 days")
    check(all.bucketMinutes(now: now, earliest: now - 10 * 365 * 1440) == 14 * 1440, "all: 2-week buckets for 10 years")
    check(all.bucketMinutes(now: now, earliest: nil) == 1440 && all.span(now: now, earliest: nil).lowerBound == now - 1440, "all with no data")
    check(!all.canPanBack(now: now, earliest: earliest) && all.panned(by: -1440, now: now, earliest: earliest) == all, "all doesn't pan")

    let switched = back.withRange(.year, now: now, earliest: earliest)
    check(switched.range == .year && switched.end == now - 1440, "range switch keeps right edge")
    check(back.withRange(.all, now: now, earliest: earliest).isLive, "switching to all goes live")

    for range in ChartRange.allCases {
        let w = ChartWindow(range: range)
        let span = w.span(now: now, earliest: now - 20 * 365 * 1440)
        let points = (span.upperBound - span.lowerBound) / w.bucketMinutes(now: now, earliest: now - 20 * 365 * 1440)
        check(points <= ChartWindow.maxPoints, "\(range.rawValue) stays ≤ \(ChartWindow.maxPoints) points (\(points))")
    }
}

// MARK: - A year of minute data: size, speed, bounded output, no memory growth

do {
    let path = NSTemporaryDirectory() + "sensortray-year-\(UUID().uuidString).sqlite"
    defer { removeDatabase(path) }
    let store = try Store(path: path)
    let s = UUID()
    store.save(SensorConfig(id: s, name: "Year", model: .h5075, isMain: true, sort: 0))

    let minutesPerYear = 365 * 1440
    let now = 29_000_000
    let start = now - minutesPerYear + 1
    // Seasonal swing (±8 °C over the year) plus a daily one (±3 °C).
    func temp(_ m: Int) -> Double {
        let t = Double(m - start)
        return 18 + 8 * sin(t / Double(minutesPerYear) * 2 * .pi) + 3 * sin(t / 1440 * 2 * .pi)
    }
    let insertStarted = Date()
    // Fed in 20-day chunks, the way a sensor backfill arrives.
    for chunk in stride(from: start, through: now, by: 28_800) {
        let points = (chunk...min(chunk + 28_799, now)).map { HistoryPoint(minute: $0, tempC: (temp($0) * 10).rounded() / 10, humidity: 55) }
        store.insertBackfill(s, points: points)
    }
    let insertSeconds = Date().timeIntervalSince(insertStarted)
    check(store.sampleCount(s) == minutesPerYear, "year: all minutes stored")
    print(String(format: "  perf: inserted %d minutes in %.2fs", minutesPerYear, insertSeconds))

    let bytes = databaseBytes(path)
    let perRow = Double(bytes) / Double(minutesPerYear)
    print(String(format: "  perf: %.1f MB on disk, %.1f bytes per minute (incl. hourly rollup)", Double(bytes) / 1_048_576, perRow))
    check(perRow < 30, "year: compact storage (\(perRow) bytes/minute)")

    let reader = try Store(path: path, readOnly: true)
    for range in ChartRange.allCases {
        let window = ChartWindow(range: range)
        let span = window.span(now: now, earliest: start)
        let bucket = window.bucketMinutes(now: now, earliest: start)
        let began = Date()
        let points = reader.aggregate(s, from: span.lowerBound, to: span.upperBound, bucketMinutes: bucket, alignOffset: 630)
        let ms = Date().timeIntervalSince(began) * 1000
        print(String(format: "  perf: %@ → %d points in %.1f ms", range.rawValue, points.count, ms))
        check(points.count <= ChartWindow.maxPoints + 1, "\(range.rawValue): bounded points (\(points.count))")
        check(!points.isEmpty, "\(range.rawValue): has data")
        check(ms < 250, "\(range.rawValue): query under 250 ms (\(ms))")
    }

    // The yearly view shows the season: winter low / summer high differ by ~16 °C.
    let yearly = reader.aggregate(s, from: start, to: now, bucketMinutes: 1440, alignOffset: 0)
    if let coldest = yearly.map(\.tempAvg).min(), let warmest = yearly.map(\.tempAvg).max() {
        check(warmest - coldest > 14, "year: seasonal swing visible (\(warmest - coldest))")
    }
    // Each day's band covers the daily ±3 °C swing.
    check(yearly.dropFirst().dropLast().allSatisfy { $0.tempMax - $0.tempMin > 5 }, "year: daily min–max band")

    // Repeated chart loads must not grow memory (statements finalized, nothing retained).
    func load() {
        for range in ChartRange.allCases {
            let w = ChartWindow(range: range)
            let span = w.span(now: now, earliest: start)
            _ = reader.aggregate(s, from: span.lowerBound, to: span.upperBound, bucketMinutes: w.bucketMinutes(now: now, earliest: start))
        }
    }
    for _ in 0..<20 { load() } // warm SQLite's page cache first
    let before = residentMB()
    for _ in 0..<300 { autoreleasepool { load() } }
    let growth = residentMB() - before
    print(String(format: "  perf: memory growth over 1,800 chart loads: %.1f MB", growth))
    check(growth < 8, "no memory growth across repeated loads (\(growth) MB)")
}

// MARK: - Philips purifier protocol

do {
    // Exact datagrams the reference client exchanged with the AC0850/70.
    let sync = PhilipsProtocol.syncRequest(messageID: 0x9181, token: hex("0e60fc23"), nonce: "EE9AC9DA")
    check(sync == hex("540291810e60fc23b3737973036465760473796e63ff4545394143394441"), "philips sync bytes")
    let observe = PhilipsProtocol.observeStatusRequest(messageID: 0x9182, token: hex("a44fcf36"))
    check(observe == hex("54019182a44fcf3660537379730364657606737461747573"), "philips observe bytes")
    check(PhilipsProtocol.ping(messageID: 0x1234) == [0x40, 0x00, 0x12, 0x34], "philips ping")
    check(PhilipsProtocol.ack(messageID: 0x1234) == [0x60, 0x00, 0x12, 0x34], "philips ack")

    let parsed = PhilipsProtocol.decode(observe)
    check(parsed?.type == .nonConfirmable && parsed?.code == 0x01 && parsed?.token == hex("a44fcf36"), "coap decode header")
    check(parsed?.options.map(\.number) == [6, 11, 11, 11] && parsed?.options.last?.value == Array("status".utf8), "coap decode options")
    check(PhilipsProtocol.decode(sync)?.payload == Array("EE9AC9DA".utf8), "coap decode payload")
    // A notification header like the device's: NON 2.05, Observe=1, Content-Format 50, Max-Age 60.
    let note = PhilipsProtocol.encode(.init(type: .nonConfirmable, code: 0x45, messageID: 22, token: hex("a44fcf36"),
                                            options: [.init(number: 6, value: [1]), .init(number: 12, value: [50]), .init(number: 14, value: [60])],
                                            payload: Array("ABC".utf8)))
    let n = PhilipsProtocol.decode(note)
    check(n?.isContent == true && n?.options.map(\.number) == [6, 12, 14] && n?.payload == Array("ABC".utf8), "coap notification roundtrip")
    let longOption = PhilipsProtocol.encode(.init(type: .confirmable, code: 1, messageID: 1, options: [.init(number: 300, value: Array(repeating: 7, count: 20))]))
    check(PhilipsProtocol.decode(longOption)?.options.first.map { $0.number == 300 && $0.value.count == 20 } == true, "coap extended option delta/length")
    check(PhilipsProtocol.decode([0x80, 0, 0, 0]) == nil && PhilipsProtocol.decode([0x40]) == nil, "coap rejects garbage")

    // Encrypted with the reference implementation (aioairctrl's scheme).
    let vector = "2174F9BA9709147C7A7B459FD0520E72676B8A0FBC0DC366081F81602EF5E3F522DA45E22899FA4218C194948E2A9CFA7A0D5791578C21C81B04FAA6EDFD95C0E0594F91F39AE2CB5DBE9F9B8335B424792CBCCE8EF6AB8A6A52E95544CA0037B68A51E4D4805C89BC8AE1CEA5876AD880EC7E882D1DE3C508BB90D166780C3582C2D9AF88B24CBF4AFFFC15557FD39326DC164746CF35CF5B9AD8B920E3A61ACD62C6CEC40E91DA1F304D9085E537D79E6ED84D86E054637A0417C1EEBF26B3CA7BAE8627CF4B66D552598B51C11A579D3D9648E159678D23294DDC83D1396457A4CA4E"
    let json = try? PhilipsProtocol.decrypt(vector)
    check(json?.hasPrefix("{\"state\":{\"reported\":{\"D01-03\":\"Bedroom\"") == true, "philips decrypt \(json ?? "nil")")
    var tampered = Array(vector.utf8)
    tampered[20] = tampered[20] == UInt8(ascii: "A") ? UInt8(ascii: "B") : UInt8(ascii: "A")
    check((try? PhilipsProtocol.decrypt(String(decoding: tampered, as: UTF8.self))) == nil, "philips rejects bad digest")
    check((try? PhilipsProtocol.decrypt("1234")) == nil, "philips rejects short payload")

    let reading = json.flatMap(PhilipsProtocol.parseStatus)
    check(reading?.pm25 == 4 && reading?.allergenIndex == 1 && reading?.isOn == true && reading?.mode == "Sleep", "philips status fields \(String(describing: reading))")
    check(reading?.filterHoursLeft == 0 && reading?.filterHoursTotal == 4800 && reading?.filterNeedsReplacing == true, "philips filter")
    check(reading?.preFilterHoursLeft == 720 && reading?.preFilterHoursTotal == 720 && reading?.filterPercentLeft == 0, "philips pre-filter")

    // Real (decrypted) status from the AC0850/70, trimmed.
    let real = #"{"state":{"reported":{"D01-03":"Bedroom","D01-05":"AC0850/70","WifiVersion":"AWS_Philips_AIR@91.1","D03-02":"ON","D03-03":false,"D03-04":0,"D03-11":"A","D03-12":"Auto General","D03-32":1,"D03-33":1,"D03-42":"PM2.5","D03-44":4,"D05-02":"A3","D05-07":720,"D05-08":4800,"D05-13":720,"D05-14":0},"desired":null}}"#
    let r = PhilipsProtocol.parseStatus(real)
    check(r?.pm25 == 1 && r?.allergenIndex == 1 && r?.mode == "Auto General", "philips real status \(String(describing: r))")

    let info = PhilipsProtocol.parseInfo(#"{"product_id":"918eab40cc3e11eca3f10217247a73aa","device_id":"ed8a883f5dbc11eea847f5bb07155e75","D01-03":"Bedroom","D01-04":"Pluto","D01-05":"AC0850/70","D01-21":"0.0.0","option":"1"}"#, host: "10.0.0.114")
    check(info?.name == "Bedroom" && info?.model == "AC0850/70" && info?.host == "10.0.0.114", "philips info")
    check(info?.sensorID?.uuidString == "ED8A883F-5DBC-11EE-A847-F5BB07155E75", "philips device id → uuid")
    check(PhilipsProtocol.uuid(forDeviceID: "xyz") == nil, "philips bad device id")
}

// MARK: - Air storage

do {
    let path = NSTemporaryDirectory() + "sensortray-air-\(UUID().uuidString).sqlite"
    defer { removeDatabase(path) }
    let store = try Store(path: path)
    let p = UUID()
    store.save(SensorConfig(id: p, name: "Bedroom", model: .philipsAir, isMain: false, sort: 0))
    let base = 2_000_040
    for m in 0..<120 { store.insertAir(p, minute: base + m, pm25: m < 60 ? 2 : 10, allergenIndex: m < 60 ? 1 : 3) }
    let hours = store.aggregateAir(p, from: base, to: base + 119, bucketMinutes: 60)
    check(hours.count == 2 && near(hours[0].pmAvg, 2) && near(hours[1].pmAvg, 10) && near(hours[1].iaiMax, 3), "air hourly rollup \(hours)")
    let fine = store.aggregateAir(p, from: base, to: base + 119, bucketMinutes: 30)
    check(fine.count == 4 && fine.allSatisfy { $0.count == 30 }, "air minute buckets")
    check(store.lastAir(p).map { $0.minute == base + 119 && $0.pm25 == 10 } == true, "air last reading")
    store.insertAir(p, minute: base + 119, pm25: 50, allergenIndex: 9)
    check(store.aggregateAir(p, from: base + 60, to: base + 119, bucketMinutes: 60).first.map { near($0.pmMax, 50) } == true, "air overwrite updates rollup")
    check(store.earliestMinute() == base, "earliest includes air")
    check(store.aggregate(p, from: base, to: base + 119, bucketMinutes: 60).isEmpty, "air not mixed into climate")
    store.delete(id: p)
    check(store.aggregateAir(p, from: base, to: base + 119, bucketMinutes: 1).isEmpty && store.earliestMinute() == nil, "air deleted with sensor")
}

// MARK: - Schema v2 → v3

do {
    let path = NSTemporaryDirectory() + "sensortray-v2-\(UUID().uuidString).sqlite"
    defer { removeDatabase(path) }
    var db: OpaquePointer?
    sqlite3_open(path, &db)
    sqlite3_exec(db, """
        CREATE TABLE sensors(key INTEGER PRIMARY KEY, id TEXT NOT NULL UNIQUE, name TEXT NOT NULL, model TEXT NOT NULL,
            is_main INTEGER NOT NULL DEFAULT 0, sort INTEGER NOT NULL DEFAULT 0, synced_through INTEGER, color TEXT, added_at INTEGER NOT NULL);
        CREATE TABLE samples(sensor INTEGER NOT NULL, minute INTEGER NOT NULL, t INTEGER NOT NULL, h INTEGER NOT NULL,
            src INTEGER NOT NULL, PRIMARY KEY(sensor, minute)) WITHOUT ROWID;
        CREATE TABLE hourly(sensor INTEGER NOT NULL, hour INTEGER NOT NULL, n INTEGER NOT NULL, t_sum INTEGER NOT NULL,
            t_min INTEGER NOT NULL, t_max INTEGER NOT NULL, h_sum INTEGER NOT NULL, h_min INTEGER NOT NULL, h_max INTEGER NOT NULL,
            PRIMARY KEY(sensor, hour)) WITHOUT ROWID;
        INSERT INTO sensors(id, name, model, added_at) VALUES('\(UUID().uuidString)', 'Kept', 'h5075', 1);
        INSERT INTO samples VALUES(1, 600, 215, 500, 0);
        PRAGMA user_version = 2;
        """, nil, nil, nil)
    sqlite3_close(db)
    let store = try Store(path: path)
    check(store.userVersion == 3 && store.sensors().first?.name == "Kept", "v2 → v3 keeps data")
    if let kept = store.sensors().first {
        check(near(store.series(kept.id, from: 0, to: 1000, bucketMinutes: 1).first?.tempC, 21.5), "v2 → v3 keeps samples")
        store.insertAir(kept.id, minute: 601, pm25: 3, allergenIndex: 1)
        check(store.lastAir(kept.id)?.pm25 == 3, "v3 air tables usable")
    }
}

// MARK: - CSV

do {
    let csv = CSV.render([HistoryPoint(minute: 29_000_000, tempC: 21.25, humidity: 48.5)], sensorName: "Bed, room")
    let lines = csv.split(separator: "\n").map(String.init)
    check(lines.first == "timestamp,sensor,temperature_c,humidity_pct", "csv header")
    check(lines.count == 2 && lines[1].hasSuffix(",\"Bed, room\",21.25,48.5"), "csv row \(lines)")
    check(lines.count == 2 && lines[1].hasPrefix("2025-02-19T21:20:00Z,"), "csv iso timestamp \(lines)")
}

print("\(passed) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
