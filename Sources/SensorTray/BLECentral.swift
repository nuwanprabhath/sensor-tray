import CoreBluetooth
import Foundation
import SensorTrayCore

/// Owns the single CBCentralManager: passive advertisement scanning for the
/// live readings, plus the connect/disconnect plumbing HistoryDownloader uses.
/// Everything runs on the main queue.
@MainActor
final class BLECentral: NSObject, CBCentralManagerDelegate {
    enum ConnectError: LocalizedError {
        case bluetoothUnavailable, unknownPeripheral, failed(String), timedOut, disconnected

        var errorDescription: String? {
            switch self {
            case .bluetoothUnavailable: return "Bluetooth is off or not permitted"
            case .unknownPeripheral: return "Sensor not seen yet — keep it near the Mac"
            case .failed(let reason): return "Connection failed: \(reason)"
            case .timedOut: return "Sensor didn't respond"
            case .disconnected: return "Sensor disconnected"
            }
        }
    }

    var onAdvert: ((Advert) -> Void)?
    var onStateChange: ((CBManagerState) -> Void)?
    /// Called when a connected peripheral drops, so an in-flight download can fail fast.
    var onDisconnect: ((UUID) -> Void)?

    private(set) var central: CBCentralManager!
    private var wantsScan = false
    private var pendingConnects: [UUID: CheckedContinuation<Void, Error>] = [:]
    /// Peripheral objects as handed out by discovery; connecting through these
    /// is more reliable than a fresh `retrievePeripherals` lookup.
    private var discovered: [UUID: CBPeripheral] = [:]
    /// Names seen in earlier scan responses; passive scans often lack them.
    private var names: [UUID: String] = [:]
    /// Models of configured sensors, so they're recognised without a name.
    var knownModels: [UUID: SensorModel] = [:]

    /// `SENSORTRAY_DEBUG=1` prints every raw advertisement.
    nonisolated static let debug = ProcessInfo.processInfo.environment["SENSORTRAY_DEBUG"] != nil

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    var state: CBManagerState { central.state }

    func startScanning() {
        wantsScan = true
        guard central.state == .poweredOn else { return }
        // Duplicates on: both brands re-advertise every few seconds and each
        // packet carries a fresh reading.
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    func stopScanning() {
        wantsScan = false
        central.stopScan()
    }

    func peripheral(id: UUID) -> CBPeripheral? {
        discovered[id] ?? central.retrievePeripherals(withIdentifiers: [id]).first
    }

    func connect(_ peripheral: CBPeripheral, timeout: TimeInterval) async throws {
        guard central.state == .poweredOn else { throw ConnectError.bluetoothUnavailable }
        let id = peripheral.identifier
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pendingConnects[id] = continuation
            central.connect(peripheral)
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self, let pending = self.pendingConnects.removeValue(forKey: id) else { return }
                self.central.cancelPeripheralConnection(peripheral)
                pending.resume(throwing: ConnectError.timedOut)
            }
        }
    }

    func disconnect(_ peripheral: CBPeripheral) {
        central.cancelPeripheralConnection(peripheral)
    }

    // MARK: CBCentralManagerDelegate

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            if central.state == .poweredOn, wantsScan { startScanning() }
            onStateChange?(central.state)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let id = peripheral.identifier
        let advertisedName = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name
        let bytes = (advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data).map { [UInt8]($0) } ?? []
        if BLECentral.debug {
            let hex = bytes.map { String(format: "%02x", $0) }.joined()
            let keys = advertisementData.keys.sorted().joined(separator: ",")
            print("[adv] \(id.uuidString.prefix(8)) \(advertisedName ?? "-") rssi \(RSSI) mfg \(hex) keys \(keys)")
        }
        MainActor.assumeIsolated {
            if let advertisedName, !advertisedName.isEmpty { names[id] = advertisedName }
            let name = names[id] ?? ""
            guard let model = SensorModel.from(advertisedName: name)
                    ?? GoveeProtocol.model(forManufacturerData: bytes)
                    ?? knownModels[id] else { return }
            let reading: Reading?
            switch model.brand {
            case .govee: reading = GoveeProtocol.parseAdvert(manufacturerData: bytes)
            case .thermopro: reading = ThermoProProtocol.parseAdvert(manufacturerData: bytes)
            }
            // Name-less packets get a placeholder until the scan response shows up.
            let displayName = name.isEmpty ? "\(model.brand.displayName) \(model.displayName)" : name
            discovered[id] = peripheral
            onAdvert?(Advert(id: id, name: displayName, model: model, reading: reading, rssi: RSSI.intValue))
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        let id = peripheral.identifier
        MainActor.assumeIsolated { pendingConnects.removeValue(forKey: id)?.resume() }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        let id = peripheral.identifier
        let reason = error?.localizedDescription ?? "unknown error"
        MainActor.assumeIsolated {
            pendingConnects.removeValue(forKey: id)?.resume(throwing: ConnectError.failed(reason))
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let id = peripheral.identifier
        MainActor.assumeIsolated {
            pendingConnects.removeValue(forKey: id)?.resume(throwing: ConnectError.disconnected)
            onDisconnect?(id)
        }
    }
}
