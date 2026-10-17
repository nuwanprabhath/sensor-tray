import CommonCrypto
import CryptoKit
import Foundation

/// What a Philips purifier reports that Sensor Tray shows.
public struct AirReading: Equatable, Sendable {
    /// PM2.5 in µg/m³.
    public var pm25: Int?
    /// Indoor allergen index, 1–12.
    public var allergenIndex: Int?
    public var isOn: Bool?
    /// e.g. "Auto General", "Sleep", "Turbo".
    public var mode: String?
    public var filterHoursLeft: Int?
    public var filterHoursTotal: Int?
    public var preFilterHoursLeft: Int?
    public var preFilterHoursTotal: Int?

    public init(pm25: Int? = nil, allergenIndex: Int? = nil, isOn: Bool? = nil, mode: String? = nil,
                filterHoursLeft: Int? = nil, filterHoursTotal: Int? = nil,
                preFilterHoursLeft: Int? = nil, preFilterHoursTotal: Int? = nil) {
        self.pm25 = pm25
        self.allergenIndex = allergenIndex
        self.isOn = isOn
        self.mode = mode
        self.filterHoursLeft = filterHoursLeft
        self.filterHoursTotal = filterHoursTotal
        self.preFilterHoursLeft = preFilterHoursLeft
        self.preFilterHoursTotal = preFilterHoursTotal
    }

    /// 0–100, nil when unknown.
    public var filterPercentLeft: Int? {
        guard let left = filterHoursLeft, let total = filterHoursTotal, total > 0 else { return nil }
        return max(0, min(100, left * 100 / total))
    }

    public var filterNeedsReplacing: Bool { filterHoursLeft == 0 }
    public var preFilterNeedsCleaning: Bool { preFilterHoursLeft == 0 }
}

/// A purifier that answered discovery.
public struct PurifierInfo: Equatable, Sendable {
    public var deviceID: String
    public var name: String
    public var model: String
    public var host: String

    public init(deviceID: String, name: String, model: String, host: String) {
        self.deviceID = deviceID
        self.name = name
        self.model = model
        self.host = host
    }

    /// Stable sensor id derived from the device's 32-hex-digit id.
    public var sensorID: UUID? { PhilipsProtocol.uuid(forDeviceID: deviceID) }
}

/// Local protocol of Philips Air+ purifiers (verified on an AC0850/70, Wi-Fi
/// firmware AWS_Philips_AIR 91.1): CoAP over UDP 5683 with an encrypted status
/// payload. Follows aioairctrl 0.3.1 (coap/client.py, coap/encryption.py).
///
/// Flow: POST /sys/dev/sync, then GET /sys/dev/status with Observe=0. The
/// device answers, and notifies again, only when a value changes, so the
/// first reading can take minutes. Read-only: nothing here posts to
/// /sys/dev/control.
public enum PhilipsProtocol {
    public static let port: UInt16 = 5683
    /// "All CoAP nodes" multicast group; the device also answers broadcast.
    public static let multicastGroup = "224.0.1.187"

    // MARK: CoAP framing (RFC 7252)

    public enum MessageType: UInt8, Sendable { case confirmable = 0, nonConfirmable = 1, acknowledgement = 2, reset = 3 }

    public struct Message: Equatable, Sendable {
        public var type: MessageType
        /// class << 5 | detail, e.g. 0x45 = 2.05 Content.
        public var code: UInt8
        public var messageID: UInt16
        public var token: [UInt8]
        public var options: [Option]
        public var payload: [UInt8]

        public struct Option: Equatable, Sendable {
            public var number: Int
            public var value: [UInt8]

            public init(number: Int, value: [UInt8]) {
                self.number = number
                self.value = value
            }
        }

        public init(type: MessageType, code: UInt8, messageID: UInt16, token: [UInt8] = [], options: [Option] = [], payload: [UInt8] = []) {
            self.type = type
            self.code = code
            self.messageID = messageID
            self.token = token
            self.options = options
            self.payload = payload
        }

        public var isContent: Bool { code == 0x45 }
    }

    static let observeOption = 6
    static let uriPathOption = 11

    public static func encode(_ m: Message) -> [UInt8] {
        var out: [UInt8] = [0x40 | (m.type.rawValue << 4) | UInt8(m.token.count), m.code,
                            UInt8(m.messageID >> 8), UInt8(m.messageID & 0xFF)]
        out += m.token
        var last = 0
        for option in m.options.sorted(by: { $0.number < $1.number }) {
            let (deltaNibble, deltaExt) = extended(option.number - last)
            let (lengthNibble, lengthExt) = extended(option.value.count)
            out.append(deltaNibble << 4 | lengthNibble)
            out += deltaExt + lengthExt + option.value
            last = option.number
        }
        if !m.payload.isEmpty { out += [0xFF] + m.payload }
        return out
    }

    private static func extended(_ value: Int) -> (UInt8, [UInt8]) {
        if value < 13 { return (UInt8(value), []) }
        if value < 269 { return (13, [UInt8(value - 13)]) }
        let v = value - 269
        return (14, [UInt8(v >> 8), UInt8(v & 0xFF)])
    }

    public static func decode(_ d: [UInt8]) -> Message? {
        guard d.count >= 4, d[0] >> 6 == 1, let type = MessageType(rawValue: (d[0] >> 4) & 3) else { return nil }
        let tokenLength = Int(d[0] & 0x0F)
        guard tokenLength <= 8, d.count >= 4 + tokenLength else { return nil }
        var i = 4 + tokenLength
        var number = 0
        var options: [Message.Option] = []
        func readExtended(_ nibble: Int) -> Int? {
            switch nibble {
            case 13: guard i < d.count else { return nil }; defer { i += 1 }; return Int(d[i]) + 13
            case 14: guard i + 1 < d.count else { return nil }; defer { i += 2 }; return (Int(d[i]) << 8 | Int(d[i + 1])) + 269
            case 15: return nil
            default: return nibble
            }
        }
        while i < d.count, d[i] != 0xFF {
            let byte = d[i]
            i += 1
            guard let delta = readExtended(Int(byte >> 4)), let length = readExtended(Int(byte & 0x0F)),
                  i + length <= d.count else { return nil }
            number += delta
            options.append(.init(number: number, value: Array(d[i..<(i + length)])))
            i += length
        }
        let payload = i < d.count ? Array(d[(i + 1)...]) : []
        return Message(type: type, code: d[1], messageID: UInt16(d[2]) << 8 | UInt16(d[3]),
                       token: Array(d[4..<(4 + tokenLength)]), options: options, payload: payload)
    }

    private static func path(_ segments: String...) -> [Message.Option] {
        segments.map { .init(number: uriPathOption, value: Array($0.utf8)) }
    }

    /// POST /sys/dev/sync with 8 hex characters; the reply is the device's counter.
    public static func syncRequest(messageID: UInt16, token: [UInt8], nonce: String) -> [UInt8] {
        encode(Message(type: .nonConfirmable, code: 0x02, messageID: messageID, token: token,
                       options: path("sys", "dev", "sync"), payload: Array(nonce.utf8)))
    }

    /// GET /sys/dev/status, Observe=0 (register).
    public static func observeStatusRequest(messageID: UInt16, token: [UInt8]) -> [UInt8] {
        encode(Message(type: .nonConfirmable, code: 0x01, messageID: messageID, token: token,
                       options: [.init(number: observeOption, value: [])] + path("sys", "dev", "status")))
    }

    /// GET /sys/dev/info: plaintext identity, used for discovery.
    public static func infoRequest(messageID: UInt16, token: [UInt8]) -> [UInt8] {
        encode(Message(type: .nonConfirmable, code: 0x01, messageID: messageID, token: token,
                       options: path("sys", "dev", "info")))
    }

    /// Empty confirmable message; the device answers with a reset in a few ms.
    public static func ping(messageID: UInt16) -> [UInt8] {
        encode(Message(type: .confirmable, code: 0, messageID: messageID))
    }

    public static func ack(messageID: UInt16) -> [UInt8] {
        encode(Message(type: .acknowledgement, code: 0, messageID: messageID))
    }

    // MARK: Payload encryption

    public enum PayloadError: Error { case tooShort, digest, hex, decrypt, utf8 }

    /// `KEY(8) + CIPHERTEXT(hex) + SHA256(64)`, all ASCII hex. The AES-128-CBC
    /// key and IV are the ASCII bytes of the two halves of
    /// MD5("JiangPan" + KEY) as uppercase hex.
    public static func decrypt(_ payload: String) throws -> String {
        let chars = Array(payload.utf8)
        guard chars.count > 8 + 64, (chars.count - 72) % 32 == 0 else { throw PayloadError.tooShort }
        let key = String(decoding: chars[0..<8], as: UTF8.self)
        let cipherHex = String(decoding: chars[8..<(chars.count - 64)], as: UTF8.self)
        let digest = String(decoding: chars[(chars.count - 64)...], as: UTF8.self)
        guard hexDigest(SHA256.hash(data: Data((key + cipherHex).utf8))) == digest.uppercased() else { throw PayloadError.digest }

        let derived = Array(hexDigest(Insecure.MD5.hash(data: Data(("JiangPan" + key).utf8))).utf8)
        guard let cipher = bytes(fromHex: cipherHex) else { throw PayloadError.hex }
        let plain = try aesCBCDecrypt(cipher, key: Array(derived[0..<16]), iv: Array(derived[16..<32]))
        guard let text = String(bytes: plain, encoding: .utf8) else { throw PayloadError.utf8 }
        return text
    }

    private static func hexDigest<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02X", $0) }.joined()
    }

    static func bytes(fromHex hex: String) -> [UInt8]? {
        let chars = Array(hex.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let hi = nibble(chars[i]), let lo = nibble(chars[i + 1]) else { return nil }
            out.append(hi << 4 | lo)
            i += 2
        }
        return out
    }

    private static func nibble(_ c: UInt8) -> UInt8? {
        switch c {
        case 48...57: return c - 48
        case 65...70: return c - 55
        case 97...102: return c - 87
        default: return nil
        }
    }

    private static func aesCBCDecrypt(_ data: [UInt8], key: [UInt8], iv: [UInt8]) throws -> [UInt8] {
        var out = [UInt8](repeating: 0, count: data.count + kCCBlockSizeAES128)
        var moved = 0
        let status = CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES128), CCOptions(kCCOptionPKCS7Padding),
                             key, key.count, iv, data, data.count, &out, out.count, &moved)
        guard status == kCCSuccess else { throw PayloadError.decrypt }
        return Array(out[0..<moved])
    }

    // MARK: JSON

    /// `{"state":{"reported":{…}}}` → the fields Sensor Tray uses. Keys per
    /// kongo09/philips-airpurifier-coap const.py ("NEW_*" family).
    public static func parseStatus(_ json: String) -> AirReading? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return nil }
        let state = object["state"] as? [String: Any]
        guard let r = (state?["reported"] as? [String: Any]) ?? (object["D03-02"] != nil ? object : nil) else { return nil }
        func int(_ key: String) -> Int? { (r[key] as? NSNumber)?.intValue }
        let power = r["D03-02"] as? String
        return AirReading(pm25: int("D03-33"), allergenIndex: int("D03-32"),
                          isOn: power.map { $0.uppercased() == "ON" }, mode: r["D03-12"] as? String,
                          filterHoursLeft: int("D05-14"), filterHoursTotal: int("D05-08"),
                          preFilterHoursLeft: int("D05-13"), preFilterHoursTotal: int("D05-07"))
    }

    /// Plaintext /sys/dev/info reply.
    public static func parseInfo(_ json: String, host: String) -> PurifierInfo? {
        guard let r = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let deviceID = r["device_id"] as? String, uuid(forDeviceID: deviceID) != nil else { return nil }
        return PurifierInfo(deviceID: deviceID, name: (r["D01-03"] as? String) ?? "Air purifier",
                            model: (r["D01-05"] as? String) ?? "Philips", host: host)
    }

    /// "ed8a883f5dbc11eea847f5bb07155e75" → ED8A883F-5DBC-11EE-A847-F5BB07155E75
    public static func uuid(forDeviceID id: String) -> UUID? {
        let hex = Array(id.uppercased())
        guard hex.count == 32, hex.allSatisfy(\.isHexDigit) else { return nil }
        let s = String(hex)
        func part(_ a: Int, _ b: Int) -> Substring { s[s.index(s.startIndex, offsetBy: a)..<s.index(s.startIndex, offsetBy: b)] }
        return UUID(uuidString: "\(part(0, 8))-\(part(8, 12))-\(part(12, 16))-\(part(16, 20))-\(part(20, 32))")
    }
}
