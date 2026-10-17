import Foundation

/// Govee H5075-family thermo-hygrometers.
///
/// Live data rides in the advertisement (manufacturer id 0xEC88); stored
/// minute-resolution history is pulled over the "INTELLI_ROCKS" GATT service.
/// Byte layouts follow github.com/wcbonner/GoveeBTTempLogger.
public enum GoveeProtocol {
    public static let serviceUUID = "494E5445-4C4C-495F-524F-434B535F4857"
    public static let deviceCharUUID = "494E5445-4C4C-495F-524F-434B535F2011"
    public static let requestCharUUID = "494E5445-4C4C-495F-524F-434B535F2012"
    public static let dataCharUUID = "494E5445-4C4C-495F-524F-434B535F2013"

    /// "GVH5075_BCAE", "GVH5072_1234" (H5072 shares the H5075 format).
    public static func model(forName name: String) -> SensorModel? {
        if name.hasPrefix("GVH5075") || name.hasPrefix("GVH5072") { return .h5075 }
        return nil
    }

    /// Recognises an H5075 by its manufacturer data alone. Needed because the
    /// name lives in the scan response, which background (passive) scans
    /// on macOS often don't receive.
    public static func model(forManufacturerData d: [UInt8]) -> SensorModel? {
        record(in: d) == nil ? nil : .h5075
    }

    /// The H5075 advertises two manufacturer records, Govee's
    /// `88 EC 00 T2 T1 T0 BB 00` and an Apple iBeacon (`4C 00 02 15 …`), and
    /// CoreBluetooth concatenates them into one blob. Finds Govee's 8 bytes.
    static func record(in d: [UInt8]) -> ArraySlice<UInt8>? {
        if d.count >= 8, d[0] == 0x88, d[1] == 0xEC { return d[0..<8] }
        // Tolerate the opposite order: iBeacon record (25 bytes) first.
        if d.count >= 33, d[0] == 0x4C, d[1] == 0x00, d[25] == 0x88, d[26] == 0xEC { return d[25..<33] }
        return nil
    }

    public static func parseAdvert(manufacturerData d: [UInt8]) -> Reading? {
        guard let r = record(in: d), let (temp, humidity) = decodePacked(r[r.startIndex + 3], r[r.startIndex + 4], r[r.startIndex + 5]) else { return nil }
        return Reading(tempC: temp, humidity: humidity, battery: Int(min(r[r.startIndex + 6], 100)))
    }

    /// Three big-endian bytes packing temperature and humidity as one decimal
    /// number: 0x03519E = 217502 → 21.7 °C, 50.2 %. Top bit is the sign.
    static func decodePacked(_ b0: UInt8, _ b1: UInt8, _ b2: UInt8) -> (Double, Double)? {
        let raw = Int(b0) << 16 | Int(b1) << 8 | Int(b2)
        if raw == 0xFFFFFF { return nil }
        let negative = raw & 0x800000 != 0
        let value = raw & 0x7FFFFF
        let temp = Double(value / 1000) / 10
        let humidity = Double(value % 1000) / 10
        guard humidity <= 100 else { return nil }
        return (negative ? -temp : temp, humidity)
    }

    /// `33 01 SS SS 00 01 …` asking for records from `minutesBack` minutes
    /// ago up to 1 minute ago, XOR checksum in the last byte.
    public static func historyRequest(minutesBack: Int) -> [UInt8] {
        let start = UInt16(clamping: max(1, minutesBack))
        return packet([0x33, 0x01, UInt8(start >> 8), UInt8(start & 0xFF), 0x00, 0x01])
    }

    /// The device stalls a long transfer unless poked every few hundred records.
    public static func keepAlive() -> [UInt8] {
        packet([0xAA, 0x01])
    }

    static func packet(_ head: [UInt8]) -> [UInt8] {
        var bytes = head + Array(repeating: 0, count: 19 - head.count)
        bytes.append(bytes.reduce(0, ^))
        return bytes
    }

    /// One `…2013` notification: big-endian offset (minutes ago of the first
    /// record) followed by up to six 3-byte records, each a minute newer.
    public static func decodeHistoryPacket(_ p: [UInt8], downloadMinute: Int) -> (offset: Int, points: [HistoryPoint]) {
        guard p.count >= 2 else { return (0, []) }
        let offset = Int(p[0]) << 8 | Int(p[1])
        var points: [HistoryPoint] = []
        var index = 2
        var minutesAgo = offset
        while index + 2 < p.count, minutesAgo > 0 {
            if let (temp, humidity) = decodePacked(p[index], p[index + 1], p[index + 2]) {
                points.append(HistoryPoint(minute: downloadMinute - minutesAgo, tempC: temp, humidity: humidity))
            }
            minutesAgo -= 1
            index += 3
        }
        return (offset, points)
    }
}
