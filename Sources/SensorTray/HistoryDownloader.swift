import CoreBluetooth
import Foundation
import SensorTrayCore

/// Connects to one sensor, pulls its onboard history over GATT, disconnects.
/// One download at a time; the connection is always torn down afterwards so
/// the vendor phone apps can still reach the sensor.
@MainActor
final class HistoryDownloader: NSObject, CBPeripheralDelegate {
    enum DownloadError: LocalizedError {
        case busy, missingCharacteristic(String), noData, discovery(String), disconnected

        var errorDescription: String? {
            switch self {
            case .busy: return "Another download is running"
            case .missingCharacteristic(let uuid): return "Sensor is missing characteristic \(uuid)"
            case .noData: return "Sensor sent no history"
            case .discovery(let reason): return "Service discovery failed: \(reason)"
            case .disconnected: return "Sensor disconnected mid-transfer"
            }
        }
    }

    private let ble: BLECentral
    private var peripheral: CBPeripheral?
    private var characteristics: [String: CBCharacteristic] = [:]
    private var busy = false

    private var discoveryContinuation: CheckedContinuation<Void, Error>?
    private var servicesPendingDiscovery = 0

    /// Notifications that arrive before a collector is installed (e.g. during
    /// the TP357S request sequence) wait here.
    private var inbox: [(bytes: [UInt8], from: String)] = []
    private var packetHandler: (([UInt8], String) -> Bool)?
    private var collectContinuation: CheckedContinuation<Bool, Error>?
    private var lastPacketAt = Date()

    init(ble: BLECentral) {
        self.ble = ble
        super.init()
        ble.onDisconnect = { [weak self] id in
            guard let self, self.peripheral?.identifier == id else { return }
            self.finishDiscovery(.failure(DownloadError.disconnected))
            self.finishCollect(.failure(DownloadError.disconnected))
        }
    }

    /// Fetches roughly the last `minutesBack` minutes (capped by what the
    /// model stores). Partial transfers return what arrived.
    func download(id: UUID, model: SensorModel, minutesBack: Int, log: ((String) -> Void)? = nil) async throws -> [HistoryPoint] {
        guard !busy else { throw DownloadError.busy }
        busy = true
        defer { busy = false }

        guard let p = ble.peripheral(id: id) else { throw BLECentral.ConnectError.unknownPeripheral }
        peripheral = p
        characteristics = [:]
        inbox = []
        p.delegate = self
        defer {
            ble.disconnect(p)
            peripheral = nil
            packetHandler = nil
        }

        // Sensors only accept a connection right after an advertisement, and
        // the first attempt often misses that window; try twice.
        for attempt in 1...2 {
            log?("connecting to \(id.uuidString) (attempt \(attempt))…")
            do {
                try await ble.connect(p, timeout: 20)
                break
            } catch BLECentral.ConnectError.timedOut where attempt == 1 {
                try await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        log?("connected, discovering services…")
        try await discover(p)
        log?("found \(characteristics.count) characteristics")

        let minutes = min(max(minutesBack, 1), model.historyRetentionMinutes)
        switch model {
        case .h5075: return try await downloadGovee(p, minutes: minutes, log: log)
        case .tp357: return try await downloadTP357(p, minutes: minutes, log: log)
        case .tp357s: return try await downloadTP357S(p, minutes: minutes, log: log)
        case .philipsAir: throw DownloadError.noData   // Wi-Fi device; nothing to download
        }
    }

    // MARK: Brand sessions

    private func downloadGovee(_ p: CBPeripheral, minutes: Int, log: ((String) -> Void)?) async throws -> [HistoryPoint] {
        try await subscribe(p, [GoveeProtocol.deviceCharUUID, GoveeProtocol.requestCharUUID, GoveeProtocol.dataCharUUID])
        let downloadMinute = Int.nowMinute()
        var points: [HistoryPoint] = []
        try write(p, GoveeProtocol.historyRequest(minutesBack: minutes), to: GoveeProtocol.requestCharUUID)
        log?("requested \(minutes) minutes")

        // ~6 records per packet; allow generous time for a full 20-day pull.
        let deadline = Date().addingTimeInterval(60 + Double(minutes) / 40)
        _ = try await collect(idleTimeout: 20, deadline: deadline) { [weak self] bytes, from in
            // Records only arrive on the data characteristic; `ee 01` on the
            // request characteristic marks the end of the transfer.
            if from == GoveeProtocol.requestCharUUID { return bytes.starts(with: [0xEE, 0x01]) && !points.isEmpty }
            guard from == GoveeProtocol.dataCharUUID else { return false }
            let packet = GoveeProtocol.decodeHistoryPacket(bytes, downloadMinute: downloadMinute)
            points += packet.points
            if packet.offset % 450 < 6, packet.offset > 6 {
                try? self?.write(p, GoveeProtocol.keepAlive(), to: GoveeProtocol.requestCharUUID)
            }
            return packet.offset <= 6
        }
        guard !points.isEmpty else { throw DownloadError.noData }
        return points
    }

    private func downloadTP357(_ p: CBPeripheral, minutes: Int, log: ((String) -> Void)?) async throws -> [HistoryPoint] {
        try await subscribe(p, [ThermoProProtocol.notifyCharUUID])
        var points = try await tp357Pass(p, request: ThermoProProtocol.dayRequest,
                                         records: ThermoProProtocol.dayRecords, stepMinutes: 1, log: log)
        if minutes > ThermoProProtocol.dayRecords {
            // Older than 24 h is only kept hourly; keep minute data where both exist.
            let oldestMinute = points.map(\.minute).min() ?? Int.nowMinute() - ThermoProProtocol.dayRecords
            let hourly = try await tp357Pass(p, request: ThermoProProtocol.weekRequest,
                                             records: ThermoProProtocol.weekRecords, stepMinutes: 60, log: log)
            points += hourly.filter { $0.minute < oldestMinute }
        }
        guard !points.isEmpty else { throw DownloadError.noData }
        return points
    }

    private func tp357Pass(_ p: CBPeripheral, request: [UInt8], records: Int, stepMinutes: Int,
                           log: ((String) -> Void)?) async throws -> [HistoryPoint] {
        let opcode = request[0]
        let expectedPackets = (records + 4) / 5
        var packets: [[UInt8]] = []
        inbox = []
        let requestMinute = Int.nowMinute()
        try write(p, request, to: ThermoProProtocol.writeCharUUID)
        log?(String(format: "requested opcode %02x", opcode))
        _ = try await collect(idleTimeout: 15, deadline: Date().addingTimeInterval(90)) { bytes, _ in
            if bytes.first == opcode {
                packets.append(bytes)
                return packets.count >= expectedPackets
            }
            // The periodic live reading marks the end of the stream.
            return bytes.first == ThermoProProtocol.liveOpcode && !packets.isEmpty
        }
        log?("received \(packets.count)/\(expectedPackets) packets")
        return ThermoProProtocol.decodeLegacyPackets(packets, opcode: opcode, requestMinute: requestMinute,
                                                     stepMinutes: stepMinutes, total: records)
    }

    private func downloadTP357S(_ p: CBPeripheral, minutes: Int, log: ((String) -> Void)?) async throws -> [HistoryPoint] {
        try await subscribe(p, [ThermoProProtocol.notifyCharUUID])
        try write(p, ThermoProProtocol.timeSync(Date()), to: ThermoProProtocol.writeCharUUID)
        try await Task.sleep(nanoseconds: 1_000_000_000)

        inbox = []
        let now = Date()
        let requestMinute = Int.nowMinute(now)
        let count = min(minutes, ThermoProProtocol.sMaxRecords)
        for command in ThermoProProtocol.sHistoryRequests(now, count: count) {
            try write(p, command, to: ThermoProProtocol.writeCharUUID)
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        log?("requested \(count) records")

        var chunks: [[UInt8]] = []
        _ = try await collect(idleTimeout: 20, deadline: Date().addingTimeInterval(90)) { bytes, _ in
            if bytes.starts(with: [0xCC, 0xCC, 0x01]) {
                chunks = [bytes]              // start (or restart) of the history stream
            } else if !chunks.isEmpty {
                if bytes.first == ThermoProProtocol.liveOpcode && bytes.count == 7 { return false }
                chunks.append(bytes)
            } else {
                return false
            }
            return chunks.last.map { $0.count >= 2 && $0.suffix(2) == [0x66, 0x66] } ?? false
        }
        let points = try ThermoProProtocol.decodeSStream(chunks.flatMap { $0 }, requestMinute: requestMinute)
        guard !points.isEmpty else { throw DownloadError.noData }
        return points
    }

    // MARK: GATT helpers

    private func discover(_ p: CBPeripheral) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            discoveryContinuation = continuation
            p.discoverServices(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
                self?.finishDiscovery(.failure(DownloadError.discovery("timed out")))
            }
        }
    }

    private func finishDiscovery(_ result: Result<Void, Error>) {
        guard let continuation = discoveryContinuation else { return }
        discoveryContinuation = nil
        continuation.resume(with: result)
    }

    private func subscribe(_ p: CBPeripheral, _ uuids: [String]) async throws {
        for uuid in uuids {
            guard let c = characteristics[uuid] else { throw DownloadError.missingCharacteristic(uuid) }
            if c.properties.contains(.notify) || c.properties.contains(.indicate) {
                p.setNotifyValue(true, for: c)
            }
        }
        // CCCD writes complete within a connection interval or two.
        try await Task.sleep(nanoseconds: 500_000_000)
    }

    private func write(_ p: CBPeripheral, _ bytes: [UInt8], to uuid: String) throws {
        guard let c = characteristics[uuid] else { throw DownloadError.missingCharacteristic(uuid) }
        let type: CBCharacteristicWriteType = c.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        p.writeValue(Data(bytes), for: c, type: type)
    }

    /// Feeds notifications to `handler` until it returns true (complete →
    /// true), or the stream idles / passes the deadline (→ false).
    private func collect(idleTimeout: TimeInterval, deadline: Date, handler: @escaping ([UInt8], String) -> Bool) async throws -> Bool {
        lastPacketAt = Date()
        let buffered = inbox
        inbox = []
        for packet in buffered where handler(packet.bytes, packet.from) { return true }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
            collectContinuation = continuation
            packetHandler = handler
            watchdog(idleTimeout: idleTimeout, deadline: deadline)
        }
    }

    private func watchdog(idleTimeout: TimeInterval, deadline: Date) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.collectContinuation != nil else { return }
            if Date().timeIntervalSince(self.lastPacketAt) > idleTimeout || Date() > deadline {
                self.finishCollect(.success(false))
            } else {
                self.watchdog(idleTimeout: idleTimeout, deadline: deadline)
            }
        }
    }

    private func finishCollect(_ result: Result<Bool, Error>) {
        packetHandler = nil
        guard let continuation = collectContinuation else { return }
        collectContinuation = nil
        continuation.resume(with: result)
    }

    // MARK: CBPeripheralDelegate

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let services = peripheral.services ?? []
        let reason = error?.localizedDescription
        MainActor.assumeIsolated {
            if let reason { return finishDiscovery(.failure(DownloadError.discovery(reason))) }
            servicesPendingDiscovery = services.count
            if services.isEmpty { return finishDiscovery(.failure(DownloadError.discovery("no services"))) }
            for service in services { peripheral.discoverCharacteristics(nil, for: service) }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let found = service.characteristics ?? []
        MainActor.assumeIsolated {
            for c in found { characteristics[c.uuid.uuidString.uppercased()] = c }
            servicesPendingDiscovery -= 1
            if servicesPendingDiscovery <= 0 { finishDiscovery(.success(())) }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let value = characteristic.value else { return }
        let bytes = [UInt8](value)
        let from = characteristic.uuid.uuidString.uppercased()
        MainActor.assumeIsolated {
            lastPacketAt = Date()
            if let handler = packetHandler {
                if handler(bytes, from) { finishCollect(.success(true)) }
            } else {
                inbox.append((bytes, from))
            }
        }
    }
}
