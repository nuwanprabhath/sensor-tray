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

struct NearbySensor: Identifiable {
    var advert: Advert
    var seenAt: Date
    var id: UUID { advert.id }
}

enum ChartRange: String, CaseIterable, Identifiable {
    case sixHours = "6H", day = "24H", week = "7D", month = "30D"

    var id: String { rawValue }
    var minutes: Int {
        switch self {
        case .sixHours: return 360
        case .day: return 1440
        case .week: return 7 * 1440
        case .month: return 30 * 1440
        }
    }
    /// Keeps every range around 150–720 points per sensor.
    var bucketMinutes: Int {
        switch self {
        case .sixHours: return 2
        case .day: return 5
        case .week: return 30
        case .month: return 60
        }
    }
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

    let store: Store
    private let ble = BLECentral()
    private lazy var downloader = HistoryDownloader(ble: ble)
    private var lastStoredMinute: [UUID: Int] = [:]
    private var syncTimer: Timer?
    private var retryWork: DispatchWorkItem?
    private var advertCounts: [UUID: Int] = [:]

    static let palette: [Color] = [.orange, .teal, .purple, .pink, .green, .indigo, .yellow, .mint]

    /// `autoSync: false` keeps tooling (e.g. `--snapshot`) from connecting to sensors.
    init(autoSync: Bool = true) {
        do {
            store = try Store(path: Store.defaultPath())
        } catch {
            NSLog("SensorTray: falling back to in-memory store: \(error)")
            store = try! Store(path: ":memory:")
        }
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
        syncTimer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncAll() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { self?.syncAll() }
        }
    }

    // MARK: Derived

    var mainSensor: SensorConfig? { sensors.first(where: \.isMain) ?? sensors.first }

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

    func series(_ id: UUID, range: ChartRange) -> [HistoryPoint] {
        let now = Int.nowMinute()
        return store.series(id, from: now - range.minutes, to: now, bucketMinutes: range.bucketMinutes)
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
        for sensor in sensors {
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
                                  isMain: sensors.isEmpty, sort: (sensors.map(\.sort).max() ?? -1) + 1)
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
        store.delete(id: id)
        latest[id] = nil
        reloadSensors()
        if !sensors.isEmpty, !sensors.contains(where: \.isMain), let first = sensors.first {
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
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "\(sensor.name).csv"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let points = store.series(id, from: 0, to: Int.nowMinute(), bucketMinutes: 1)
        do {
            try CSV.render(points, sensorName: sensor.name).write(to: url, atomically: true, encoding: .utf8)
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
            for sensor in sensors {
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

    /// Weak links (a sensor in another room) often fail to connect once and
    /// succeed a bit later; don't wait for the 6-hour cycle.
    private func scheduleRetry() {
        let work = DispatchWorkItem { [weak self] in self?.syncAll() }
        retryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 600, execute: work)
    }
}
