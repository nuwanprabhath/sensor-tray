import AppKit
import os
import CoreBluetooth
import SensorTrayCore
import SwiftUI
import UniformTypeIdentifiers

let log = Logger(subsystem: "com.nuwan.sensor-tray", category: "app")

struct LiveReading: Equatable {
    var reading: Reading
    var at: Date

    /// Both brands advertise every few seconds; 10 minutes of silence means
    /// the sensor is out of range or the Mac was asleep.
    var isStale: Bool { Date().timeIntervalSince(at) > 600 }
}

/// The latest known state of an air purifier.
struct LiveAir: Equatable {
    var reading: AirReading
    /// When the purifier last reported (it only reports changes).
    var updatedAt: Date
    /// Reported during this run, so it's safe to carry forward minute by minute.
    var isFresh: Bool
    var status: PhilipsClient.Status
}

struct NearbySensor: Identifiable {
    var advert: Advert
    var seenAt: Date
    var id: UUID { advert.id }
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var sensors: [SensorConfig] = []
    @Published private(set) var latest: [UUID: LiveReading] = [:]
    @Published private(set) var nearby: [UUID: NearbySensor] = [:]
    @Published private(set) var bluetoothState: CBManagerState = .unknown
    @Published private(set) var syncStatus: String?
    @Published private(set) var isSyncing = false
    @Published private(set) var lastSync: Date?
    @Published private(set) var lastSyncError: String?
    /// Bumped whenever stored readings change so charts re-query.
    @Published private(set) var dataVersion = 0
    @Published private(set) var air: [UUID: LiveAir] = [:]
    /// Purifiers that answered the last network discovery, by sensor id.
    @Published private(set) var discoveredPurifiers: [UUID: PurifierInfo] = [:]
    @Published private(set) var isDiscoveringPurifiers = false

    let store: Store
    /// Chart queries run on their own read-only connection, off the main thread.
    let charts: ChartModel
    private let ble = BLECentral()
    private lazy var downloader = HistoryDownloader(ble: ble)
    private var lastStoredMinute: [UUID: Int] = [:]
    private var syncTimer: Timer?
    private var retryWork: DispatchWorkItem?
    private var advertCounts: [UUID: Int] = [:]
    private var purifierClients: [UUID: PhilipsClient] = [:]
    private var lastAirMinute: [UUID: Int] = [:]
    private var airTimer: Timer?
    private var lastDiscovery: Date?

    static let palette: [Color] = [.orange, .teal, .purple, .pink, .green, .indigo, .yellow, .mint]

    /// `autoSync: false` keeps tooling (e.g. `--snapshot`) from connecting to sensors.
    init(autoSync: Bool = true) {
        var path = Store.defaultPath()
        do {
            store = try Store(path: path)
        } catch {
            // A scratch file rather than ":memory:", so the chart reader's
            // second connection can still open it.
            NSLog("SensorTray: falling back to a temporary store: \(error)")
            path = NSTemporaryDirectory() + "sensortray-fallback.sqlite"
            store = try! Store(path: path)
        }
        charts = ChartModel(reader: try? Store(path: path, readOnly: true))
        reloadSensors()
        restoreLastReadings()

        ble.onStateChange = { [weak self] state in
            guard let self else { return }
            log.info("bluetooth state \(state.rawValue, privacy: .public)")
            let becameAvailable = state == .poweredOn && self.bluetoothState != .poweredOn
            self.bluetoothState = state
            // The first sync may have been skipped while the permission
            // prompt was up; let the scanner see the sensors, then sync.
            if becameAvailable && autoSync {
                DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in self?.syncAll() }
            }
        }
        ble.onAdvert = { [weak self] advert in self?.handle(advert) }
        ble.startScanning()

        guard autoSync else { return }
        startPurifiers()
        syncTimer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncAll() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { self?.syncAll() }
        }
    }

    // MARK: Derived

    /// The thermometer shown in the menu bar (purifiers have no temperature).
    var mainSensor: SensorConfig? {
        let thermometers = sensors.filter { !$0.model.isAirPurifier }
        return thermometers.first(where: \.isMain) ?? thermometers.first
    }

    var hasPurifiers: Bool { sensors.contains { $0.model.isAirPurifier } }

    /// Purifiers found on the network that aren't added yet.
    var unconfiguredPurifiers: [PurifierInfo] {
        let configured = Set(sensors.map(\.id))
        return discoveredPurifiers.values
            .filter { $0.sensorID.map { !configured.contains($0) } ?? false }
            .sorted { $0.name < $1.name }
    }

    func color(for sensor: SensorConfig) -> Color {
        if let hex = sensor.colorHex, let picked = Color(hex: hex) { return picked }
        let index = sensors.firstIndex(where: { $0.id == sensor.id }) ?? 0
        return Self.palette[index % Self.palette.count]
    }

    /// Discovered sensors not yet added, strongest signal first.
    var unconfiguredNearby: [NearbySensor] {
        let configured = Set(sensors.map(\.id))
        return nearby.values
            .filter { !configured.contains($0.id) && Date().timeIntervalSince($0.seenAt) < 120 }
            .sorted { $0.advert.rssi > $1.advert.rssi }
    }

    // MARK: Live data

    private func handle(_ advert: Advert) {
        nearby[advert.id] = NearbySensor(advert: advert, seenAt: Date())
        guard let reading = advert.reading, sensors.contains(where: { $0.id == advert.id }) else { return }
        latest[advert.id] = LiveReading(reading: reading, at: Date())
        let minute = Int.nowMinute()
        advertCounts[advert.id, default: 0] += 1
        if lastStoredMinute[advert.id] != minute {
            log.debug("stored \(advert.name, privacy: .public): \(self.advertCounts[advert.id] ?? 0, privacy: .public) adverts since last minute")
            advertCounts[advert.id] = 0
            lastStoredMinute[advert.id] = minute
            store.insertLive(advert.id, minute: minute, reading: reading)
            dataVersion += 1
        }
    }

    private func restoreLastReadings() {
        for sensor in sensors where sensor.model.isAirPurifier {
            guard let last = store.lastAir(sensor.id) else { continue }
            air[sensor.id] = LiveAir(reading: AirReading(pm25: last.pm25, allergenIndex: last.allergenIndex),
                                     updatedAt: Date(timeIntervalSince1970: TimeInterval(last.minute * 60)),
                                     isFresh: false, status: .connecting)
        }
        for sensor in sensors where !sensor.model.isAirPurifier {
            guard let minute = store.lastMinute(sensor.id),
                  let point = store.series(sensor.id, from: minute, to: minute, bucketMinutes: 1).first else { continue }
            latest[sensor.id] = LiveReading(reading: Reading(tempC: point.tempC, humidity: point.humidity, battery: nil),
                                            at: point.date)
        }
    }

    // MARK: Sensor management

    func add(_ nearbySensor: NearbySensor) {
        let advert = nearbySensor.advert
        let defaultName = advert.model.brand.displayName + " " + advert.model.displayName
        let sensor = SensorConfig(id: advert.id, name: defaultName, model: advert.model,
                                  isMain: mainSensor == nil, sort: (sensors.map(\.sort).max() ?? -1) + 1)
        store.save(sensor)
        reloadSensors()
        if let reading = advert.reading {
            latest[advert.id] = LiveReading(reading: reading, at: nearbySensor.seenAt)
        }
        syncAll()
    }

    func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard var sensor = sensors.first(where: { $0.id == id }), !trimmed.isEmpty, trimmed != sensor.name else { return }
        sensor.name = trimmed
        store.save(sensor)
        reloadSensors()
    }

    /// nil goes back to the default palette color.
    func setColor(_ id: UUID, to color: Color?) {
        store.setColor(id: id, hex: color?.hexString)
        reloadSensors()
    }

    func setMain(_ id: UUID) {
        store.setMain(id: id)
        reloadSensors()
    }

    func remove(_ id: UUID) {
        purifierClients.removeValue(forKey: id)?.stop()
        store.delete(id: id)
        latest[id] = nil
        air[id] = nil
        reloadSensors()
        if let first = mainSensor, !first.isMain {
            setMain(first.id)
        }
        dataVersion += 1
    }

    func move(_ id: UUID, by delta: Int) {
        var ordered = sensors
        guard let index = ordered.firstIndex(where: { $0.id == id }) else { return }
        let target = index + delta
        guard ordered.indices.contains(target) else { return }
        ordered.swapAt(index, target)
        for (i, var sensor) in ordered.enumerated() {
            sensor.sort = i
            store.save(sensor)
        }
        reloadSensors()
    }

    private func reloadSensors() {
        sensors = store.sensors()
        ble.knownModels = Dictionary(uniqueKeysWithValues: sensors.map { ($0.id, $0.model) })
    }

    // MARK: Export

    func exportCSV(_ id: UUID) {
        guard let sensor = sensors.first(where: { $0.id == id }) else { return }
        let csv: String
        if sensor.model.isAirPurifier {
            csv = CSV.renderAir(store.aggregateAir(id, from: 0, to: Int.nowMinute(), bucketMinutes: 1), sensorName: sensor.name)
        } else {
            csv = CSV.render(store.series(id, from: 0, to: Int.nowMinute(), bucketMinutes: 1), sensorName: sensor.name)
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "\(sensor.name).csv"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try csv.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    // MARK: History backfill

    /// For each sensor in turn, download whatever stretch of its onboard
    /// history the store is missing. Never runs two at once.
    func syncAll() {
        guard !isSyncing, bluetoothState == .poweredOn, !sensors.isEmpty else {
            log.info("sync skipped: syncing=\(self.isSyncing, privacy: .public) bt=\(self.bluetoothState.rawValue, privacy: .public)")
            return
        }
        retryWork?.cancel()
        isSyncing = true
        lastSyncError = nil
        Task { @MainActor in
            var errors: [String] = []
            for sensor in sensors where !sensor.model.isAirPurifier {
                let now = Int.nowMinute()
                guard let gapStart = store.oldestGapStart(sensor.id, now: now, windowMinutes: sensor.model.historyRetentionMinutes, minGap: 5) else { continue }
                guard let seen = nearby[sensor.id], Date().timeIntervalSince(seen.seenAt) < 120 else {
                    log.info("sync \(sensor.name, privacy: .public): not seen recently")
                    errors.append("\(sensor.name): out of range")
                    continue
                }
                syncStatus = "Syncing \(sensor.name)…"
                log.info("sync \(sensor.name, privacy: .public): \(now - gapStart + 1, privacy: .public) minutes")
                do {
                    let points = try await downloader.download(id: sensor.id, model: sensor.model, minutesBack: now - gapStart + 1) { message in
                        log.debug("\(sensor.name, privacy: .public): \(message, privacy: .public)")
                    }
                    store.insertBackfill(sensor.id, points: points)
                    if let newest = points.map(\.minute).max() {
                        store.setSyncedThrough(sensor.id, minute: newest)
                    }
                    dataVersion += 1
                    log.info("sync \(sensor.name, privacy: .public): stored \(points.count, privacy: .public) points")
                } catch {
                    log.error("sync \(sensor.name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                    errors.append("\(sensor.name): \(error.localizedDescription)")
                }
            }
            isSyncing = false
            syncStatus = nil
            lastSync = Date()
            if errors.isEmpty {
                lastSyncError = nil
            } else {
                lastSyncError = errors.joined(separator: "\n")
                scheduleRetry()
            }
        }
    }

    // MARK: Air purifiers

    /// Connects configured purifiers (cached address first, then discovery)
    /// and records their PM2.5 every minute while they're reachable.
    private func startPurifiers() {
        for sensor in sensors where sensor.model.isAirPurifier {
            if let host = UserDefaults.standard.string(forKey: Self.hostKey(sensor.id)) {
                connectPurifier(sensor.id, host: host)
            }
        }
        if hasPurifiers { discoverPurifiers() }
        airTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.airTick() }
        }
    }

    private static func hostKey(_ id: UUID) -> String { "purifierHost.\(id.uuidString)" }

    /// Probes the LAN for purifiers; (re)connects configured ones at their current address.
    func discoverPurifiers() {
        guard !isDiscoveringPurifiers else { return }
        isDiscoveringPurifiers = true
        lastDiscovery = Date()
        Task { @MainActor in
            let found = await PhilipsDiscovery.discover()
            isDiscoveringPurifiers = false
            for info in found {
                guard let id = info.sensorID else { continue }
                discoveredPurifiers[id] = info
                if sensors.contains(where: { $0.id == id }) {
                    connectPurifier(id, host: info.host)
                }
            }
        }
    }

    func addPurifier(_ info: PurifierInfo) {
        guard let id = info.sensorID else { return }
        // The purifier is usually named after its room, like a thermometer there.
        let name = sensors.contains { $0.name == info.name } ? "\(info.name) purifier" : info.name
        let sensor = SensorConfig(id: id, name: name, model: .philipsAir, isMain: false,
                                  sort: (sensors.map(\.sort).max() ?? -1) + 1)
        store.save(sensor)
        reloadSensors()
        connectPurifier(id, host: info.host)
    }

    private func connectPurifier(_ id: UUID, host: String) {
        if let existing = purifierClients[id], existing.host == host { return }
        purifierClients.removeValue(forKey: id)?.stop()
        UserDefaults.standard.set(host, forKey: Self.hostKey(id))
        let client = PhilipsClient(host: host)
        client.onReading = { [weak self] reading in self?.handleAir(id, reading) }
        client.onStatus = { [weak self] status in
            guard let self else { return }
            if var live = self.air[id] {
                live.status = status
                self.air[id] = live
            } else if status != .connecting {
                self.air[id] = LiveAir(reading: AirReading(), updatedAt: .distantPast, isFresh: false, status: status)
            }
            // The address may have changed (DHCP); look again.
            if status == .unreachable { self.discoverPurifiers() }
        }
        purifierClients[id] = client
        client.start()
        log.info("purifier \(id.uuidString, privacy: .public) at \(host, privacy: .public)")
    }

    private func handleAir(_ id: UUID, _ reading: AirReading) {
        var merged = air[id]?.reading ?? AirReading()
        // A report may omit fields; keep what we knew.
        merged.pm25 = reading.pm25 ?? merged.pm25
        merged.allergenIndex = reading.allergenIndex ?? merged.allergenIndex
        merged.isOn = reading.isOn ?? merged.isOn
        merged.mode = reading.mode ?? merged.mode
        merged.filterHoursLeft = reading.filterHoursLeft ?? merged.filterHoursLeft
        merged.filterHoursTotal = reading.filterHoursTotal ?? merged.filterHoursTotal
        merged.preFilterHoursLeft = reading.preFilterHoursLeft ?? merged.preFilterHoursLeft
        merged.preFilterHoursTotal = reading.preFilterHoursTotal ?? merged.preFilterHoursTotal
        air[id] = LiveAir(reading: merged, updatedAt: Date(), isFresh: true, status: .reachable)
        storeAir(id, force: true)
    }

    /// The purifier only reports changes, so its last report holds until the
    /// next one: record it every minute while the purifier is reachable.
    private func airTick() {
        var stored = false
        for id in air.keys { stored = storeAir(id, force: false) || stored }
        if stored { dataVersion += 1 }
        let anyDown = sensors.contains { $0.model.isAirPurifier && air[$0.id]?.status != .reachable }
        if anyDown, Date().timeIntervalSince(lastDiscovery ?? .distantPast) > 300 { discoverPurifiers() }
    }

    @discardableResult
    private func storeAir(_ id: UUID, force: Bool) -> Bool {
        guard let live = air[id], live.isFresh, live.status == .reachable,
              let pm = live.reading.pm25, let iai = live.reading.allergenIndex else { return false }
        let minute = Int.nowMinute()
        guard force || lastAirMinute[id] != minute else { return false }
        lastAirMinute[id] = minute
        store.insertAir(id, minute: minute, pm25: pm, allergenIndex: iai)
        if force { dataVersion += 1 }
        return true
    }

    /// Weak links (a sensor in another room) often fail to connect once and
    /// succeed a bit later; don't wait for the 6-hour cycle.
    private func scheduleRetry() {
        let work = DispatchWorkItem { [weak self] in self?.syncAll() }
        retryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 600, execute: work)
    }
}
