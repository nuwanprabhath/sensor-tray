import Foundation
import SensorTrayCore

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
