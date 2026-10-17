import Foundation

/// ThermoPro TP357 / TP357S thermo-hygrometers.
///
/// Live data rides in the advertisement (the company id field is abused for
/// data); history is pulled over a vendor GATT service. Byte layouts follow
/// github.com/Bluetooth-Devices/thermopro-ble (adverts), github.com/alexpacini/tpy357
/// (TP357 history) and github.com/pasky/tp357 (TP357S history).
public enum ThermoProProtocol {
    public static let notifyCharUUID = "00010203-0405-0607-0809-0A0B0C0D2B10"
    public static let writeCharUUID = "00010203-0405-0607-0809-0A0B0C0D2B11"

    /// First byte of the periodic live-reading notification on a connection;
    /// on the TP357 it also marks the end of a history stream.
    public static let liveOpcode: UInt8 = 0xC2

    /// "TP357 (7216)", "TP357S (ABCD)"; other TP3xx share the TP357 format.
    public static func model(forName name: String) -> SensorModel? {
        if name.hasPrefix("TP357S") { return .tp357s }
        if name.hasPrefix("TP3") { return .tp357 }
        return nil
    }

    /// Whole CoreBluetooth manufacturer data buffer `d` (company id + payload):
    /// temp = Int16LE(d[1], d[2]) / 10, humidity = d[3], battery = d[4] & 3.
    public static func parseAdvert(manufacturerData d: [UInt8]) -> Reading? {
        guard d.count >= 5 else { return nil }
        if d[1] == 0xFF, d[2] == 0xFF, d[3] == 0xFF { return nil }
        let temp = Double(Int16(bitPattern: UInt16(d[1]) | UInt16(d[2]) << 8)) / 10
        let humidity = Double(d[3])
        guard humidity <= 100, temp > -50, temp < 100 else { return nil }
        let battery: Int?
        switch d[4] & 3 {
        case 0: battery = 10
        case 1: battery = 50
        case 2: battery = 100
        default: battery = nil
        }
        return Reading(tempC: temp, humidity: humidity, battery: battery)
    }

    // MARK: TP357 history

    /// Last 24 h at one-minute resolution: 1440 records, oldest first.
    public static let dayRequest: [UInt8] = [0xA7, 0x00, 0x00, 0x00, 0x00, 0x7A]
    public static let dayRecords = 1440
    /// Last 7 days at one-hour resolution: 168 records, oldest first.
    public static let weekRequest: [UInt8] = [0xA6, 0x00, 0x00, 0x00, 0x00, 0x6A]
    public static let weekRecords = 168

    /// Packets are `OP II II FF` + five 3-byte records (Int16LE temp/10, hum)
    /// where IIII is the 1-based packet index. Record k (0-based, overall) of
    /// `total` is `(total - 1 - k) * stepMinutes` before `requestMinute`.
    public static func decodeLegacyPackets(_ packets: [[UInt8]], opcode: UInt8, requestMinute: Int, stepMinutes: Int, total: Int) -> [HistoryPoint] {
        var points: [HistoryPoint] = []
        for p in packets where p.count >= 7 && p[0] == opcode {
            let packetIndex = Int(p[1]) | Int(p[2]) << 8
            guard packetIndex >= 1 else { continue }
            for i in 0..<5 {
                let offset = 4 + i * 3
                guard offset + 2 < p.count else { break }
                let rawTemp = Int16(bitPattern: UInt16(p[offset]) | UInt16(p[offset + 1]) << 8)
                let humidity = p[offset + 2]
                if rawTemp == -1 || rawTemp > 1024 || humidity > 100 { continue }
                let k = (packetIndex - 1) * 5 + i
                guard k < total else { continue }
                points.append(HistoryPoint(
                    minute: requestMinute - (total - 1 - k) * stepMinutes,
                    tempC: Double(rawTemp) / 10,
                    humidity: Double(humidity)
                ))
            }
        }
        return points
    }

    // MARK: TP357S history

    /// Required handshake before the TP357S answers history requests.
    public static func timeSync(_ date: Date, calendar: Calendar = .current) -> [UInt8] {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .weekday], from: date)
        // Python's weekday()+1: Monday = 1 … Sunday = 7. Calendar.weekday: Sunday = 1.
        let dow = ((c.weekday ?? 1) + 5) % 7 + 1
        let body: [UInt8] = [
            0xA5, UInt8((c.year ?? 2000) % 100), UInt8(c.month ?? 1), UInt8(c.day ?? 1),
            UInt8(c.hour ?? 0), UInt8(c.minute ?? 0), UInt8(c.second ?? 0), UInt8(dow),
        ]
        return body + [checksum(body)]
    }

    /// Three `cccc … 6666` framed writes, sent ~200 ms apart after `timeSync`.
    public static func sHistoryRequests(_ date: Date, count: Int, calendar: Calendar = .current) -> [[UInt8]] {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let body: [UInt8] = [
            0x01, 0x09, 0x00, 0x00, 0x00,
            UInt8((c.year ?? 2000) % 100), UInt8(c.month ?? 1), UInt8(c.day ?? 1),
            UInt8(c.hour ?? 0), UInt8(c.minute ?? 0), UInt8(c.second ?? 0),
            UInt8(count & 0xFF), UInt8((count >> 8) & 0xFF),
        ]
        return [
            [0xCC, 0xCC, 0x02, 0x01, 0x00, 0x00, 0x01, 0x04, 0x66, 0x66],
            [0xCC, 0xCC, 0x04, 0x00, 0x00, 0x00, 0x04, 0x66, 0x66],
            [0xCC, 0xCC] + body + [checksum(body), 0x66, 0x66],
        ]
    }

    /// The firmware ignores requests beyond 20 days of minute records.
    public static let sMaxRecords = 28_800

    public enum StreamError: Error { case framing, length, checksum }

    /// Reassembled stream `cc cc 01 [len x3 LE] 00 [records] cksum 66 66`,
    /// records most recent first, one per minute ending at `requestMinute`.
    public static func decodeSStream(_ buf: [UInt8], requestMinute: Int) throws -> [HistoryPoint] {
        guard buf.count >= 10, buf[0] == 0xCC, buf[1] == 0xCC, buf[2] == 0x01,
              buf[buf.count - 2] == 0x66, buf[buf.count - 1] == 0x66 else { throw StreamError.framing }
        let inner = Array(buf[2..<(buf.count - 2)])
        let declared = Int(inner[1]) | Int(inner[2]) << 8 | Int(inner[3]) << 16
        let records = Array(inner[5..<(inner.count - 1)])
        guard records.count % 3 == 0, declared == records.count + 1 else { throw StreamError.length }
        guard checksum(inner.dropLast()) == inner[inner.count - 1] else { throw StreamError.checksum }
        var points: [HistoryPoint] = []
        for (n, i) in stride(from: 0, to: records.count, by: 3).enumerated() {
            let rawTemp = Int16(bitPattern: UInt16(records[i]) | UInt16(records[i + 1]) << 8)
            let humidity = records[i + 2]
            if rawTemp == -1 || humidity > 100 { continue }
            points.append(HistoryPoint(minute: requestMinute - n, tempC: Double(rawTemp) / 10, humidity: Double(humidity)))
        }
        return points
    }

    static func checksum<C: Collection>(_ bytes: C) -> UInt8 where C.Element == UInt8 {
        UInt8(bytes.reduce(0) { ($0 + Int($1)) & 0xFF })
    }
}
