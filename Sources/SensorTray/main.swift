import AppKit
import CoreBluetooth
import Foundation
import SwiftUI
import SensorTrayCore

// CLI escape hatches for testing the Bluetooth layer without the GUI:
//   SensorTray --scan [seconds]           list nearby Govee/ThermoPro sensors with live readings
//   SensorTray --history <uuid> [minutes] download a sensor's stored history (default 60 min)
//   SensorTray --dump                     print configured sensors and stored data ranges
//   SensorTray --purifier [seconds]       find Philips purifiers on the LAN and print their status updates
//   SensorTray --snapshot <png> [light|dark] [sensors] [--range 1Y] render the popover (or Sensors window)
//   SensorTray --generate-demo <db> [years]  synthetic multi-year database for UI/perf testing
//   SENSORTRAY_DB=<db> SensorTray …          use another database (e.g. a demo or a copy of real data)
let arguments = CommandLine.arguments

func argument(after flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag), arguments.count > index + 1 else { return nil }
    return arguments[index + 1]
}

func describe(_ reading: Reading?) -> String {
    guard let r = reading else { return "(no reading)" }
    let battery = r.battery.map { " batt \($0)%" } ?? ""
    return String(format: "%.1f°C %.1f%%", r.tempC, r.humidity) + battery
}

if arguments.contains("--scan") {
    MainActor.assumeIsolated { CLI.scan() }
} else if arguments.contains("--history") {
    MainActor.assumeIsolated { CLI.history() }
} else if arguments.contains("--purifier") {
    MainActor.assumeIsolated { CLI.purifier() }
} else if arguments.contains("--generate-demo") {
    try MainActor.assumeIsolated { try CLI.generateDemo() }
} else if arguments.contains("--snapshot") {
    MainActor.assumeIsolated { CLI.snapshot() }
} else if arguments.contains("--dump") {
    try MainActor.assumeIsolated { try CLI.dump() }
} else {
    SensorTrayApp.main()
}

@MainActor
enum CLI {
    static func scan() {
        let seconds = argument(after: "--scan").flatMap(Double.init) ?? 15
        let ble = BLECentral()
        var seen: [UUID: Advert] = [:]
        var counts: [UUID: (all: Int, withReading: Int)] = [:]
        ble.onStateChange = { state in
            if state != .poweredOn { print("Bluetooth state: \(state.rawValue) (5 = on)") }
        }
        ble.onAdvert = { advert in
            counts[advert.id, default: (0, 0)].all += 1
            if advert.reading != nil { counts[advert.id, default: (0, 0)].withReading += 1 }
            let first = seen[advert.id] == nil
            let changed = seen[advert.id]?.reading != advert.reading && advert.reading != nil
            seen[advert.id] = advert
            if first || changed {
                print("\(advert.id.uuidString)  \(advert.name.padding(toLength: 16, withPad: " ", startingAt: 0))  \(advert.model.displayName.padding(toLength: 6, withPad: " ", startingAt: 0))  \(describe(advert.reading))  rssi \(advert.rssi)")
            }
        }
        ble.startScanning()
        print("Scanning for \(Int(seconds))s…")
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        print("Found \(seen.count) sensor(s).")
        for (id, count) in counts {
            print("  \(seen[id]?.name ?? id.uuidString): \(count.all) adverts, \(count.withReading) with a reading")
        }
    }

    static func history() {
        guard let idString = argument(after: "--history"), let id = UUID(uuidString: idString) else {
            print("Usage: --history <uuid> [minutes]   (get the uuid from --scan)")
            return
        }
        let minutes = arguments.last.flatMap(Int.init) ?? 60
        let ble = BLECentral()
        let downloader = HistoryDownloader(ble: ble)
        var model: SensorModel?
        var done = false
        ble.onAdvert = { advert in
            guard advert.id == id, model == nil else { return }
            model = advert.model
            print("Found \(advert.name) (\(advert.model.displayName)) \(describe(advert.reading))")
            Task { @MainActor in
                let started = Date()
                do {
                    let points = try await downloader.download(id: id, model: advert.model, minutesBack: minutes) { print("  \($0)") }
                    let sorted = points.sorted { $0.minute < $1.minute }
                    let formatter = DateFormatter()
                    formatter.dateFormat = "yyyy-MM-dd HH:mm"
                    print("Downloaded \(points.count) points in \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
                    if let first = sorted.first, let last = sorted.last {
                        print("  range \(formatter.string(from: first.date)) → \(formatter.string(from: last.date))")
                    }
                    for p in sorted.suffix(5) {
                        print("  \(formatter.string(from: p.date))  \(String(format: "%.1f°C %.1f%%", p.tempC, p.humidity))")
                    }
                } catch {
                    print("Download failed: \(error.localizedDescription)")
                }
                done = true
            }
        }
        ble.startScanning()
        print("Looking for \(id.uuidString)…")
        let giveUp = Date().addingTimeInterval(30)
        while !done {
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            if model == nil && Date() > giveUp {
                print("Sensor not seen within 30s.")
                break
            }
        }
    }

    static func snapshot() {
        guard let path = argument(after: "--snapshot") else {
            print("Usage: --snapshot <file.png> [light|dark] [sensors]")
            return
        }
        let dark = arguments.contains("dark")
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let model = AppModel(autoSync: false)
        model.charts.setRange(ChartRange(rawValue: argument(after: "--range") ?? "") ?? .day, persist: false)
        // Let a few advertisements arrive so the cards show live values.
        RunLoop.main.run(until: Date().addingTimeInterval(12))

        // Fixed chart settings in a throwaway defaults suite, so the image is
        // reproducible and the app's own preferences aren't touched.
        let suite = "com.nuwan.sensor-tray.snapshot"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(ChartMetric.temperature.rawValue, forKey: "chartMetric")
        defer { defaults.removePersistentDomain(forName: suite) }

        let root = Group {
            if arguments.contains("sensors") { SensorsView() } else { PopoverView() }
        }
            .defaultAppStorage(defaults)
            .environmentObject(model)
            .environmentObject(model.charts)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, dark ? .dark : .light)
        let host = NSHostingView(rootView: root)
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.frame = CGRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.appearance = host.appearance
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(1))

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            print("Wrote \(path) (\(Int(host.bounds.width))x\(Int(host.bounds.height)) pt)")
            let label = MenuBarLabel.render(text: "25.1°  62%", dimmed: false)
            if let tiff = label.tiffRepresentation, let labelPNG = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try labelPNG.write(to: URL(fileURLWithPath: path.replacingOccurrences(of: ".png", with: "-label.png")))
            }
        } catch {
            print("Failed to write \(path): \(error.localizedDescription)")
        }
    }

    /// Two sensors with seasonal (southern-hemisphere) and daily cycles, one
    /// reading per minute, ending now. Never touches the real database.
    static func generateDemo() throws {
        guard let path = argument(after: "--generate-demo") else {
            print("Usage: --generate-demo <file.sqlite> [years]")
            return
        }
        guard path != Store.defaultPath() else {
            print("Refusing to overwrite the app's database.")
            return
        }
        let years = arguments.last.flatMap(Double.init) ?? 2
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
        let store = try Store(path: path)
        let rooms: [(String, SensorModel, Double, Double)] = [("Living room", .h5075, 21, 6), ("Bedroom", .tp357s, 19, 7)]
        let now = Int.nowMinute()
        let total = Int(years * 365 * 1440)
        let started = Date()
        for (index, room) in rooms.enumerated() {
            let id = UUID()
            store.save(SensorConfig(id: id, name: room.0, model: room.1, isMain: index == 0, sort: index))
            for chunk in stride(from: now - total, through: now, by: 28_800) {
                let points = (chunk...min(chunk + 28_799, now)).map { m -> HistoryPoint in
                    let t = Double(m)
                    // Peak warmth in late January, coldest in July; warmest mid-afternoon.
                    let season = cos((t / 1440 - 25) / 365.25 * 2 * .pi)
                    let day = sin(((t + 570) / 1440 - 0.375) * 2 * .pi)
                    let noise = sin(t * 0.37) * 0.3 + sin(t * 0.011) * 0.6
                    let temp = room.2 + room.3 * season + 2.5 * day + noise
                    let humidity = 55 - 12 * season - 6 * day + noise * 3
                    return HistoryPoint(minute: m, tempC: (temp * 10).rounded() / 10, humidity: (humidity * 10).rounded() / 10)
                }
                store.insertBackfill(id, points: points)
            }
        }
        print(String(format: "Wrote %@: %d sensors × %d minutes in %.1fs", path, rooms.count, total, Date().timeIntervalSince(started)))
    }

    static func purifier() {
        let seconds = argument(after: "--purifier").flatMap(Double.init) ?? 60
        var done = false
        var client: PhilipsClient?
        Task { @MainActor in
            let found = await PhilipsDiscovery.discover()
            guard let info = found.first else {
                print("No Philips purifier answered on the local network.")
                done = true
                return
            }
            for p in found { print("Found \(p.name) (\(p.model)) at \(p.host), id \(p.sensorID?.uuidString ?? p.deviceID)") }
            let c = PhilipsClient(host: info.host)
            c.onStatus = { print("  status: \($0)") }
            c.onReading = { r in
                let filter = r.filterPercentLeft.map { "\($0)%" } ?? "?"
                print("  \(Date().formatted(date: .omitted, time: .standard))  PM2.5 \(r.pm25.map(String.init) ?? "?") µg/m³  IAI \(r.allergenIndex.map(String.init) ?? "?")  \(r.isOn == true ? "on" : "off") · \(r.mode ?? "?")  filter \(filter)\(r.filterNeedsReplacing ? " (replace)" : "")")
            }
            c.start()
            client = c
            print("Observing for \(Int(seconds))s — the purifier only reports when a value changes.")
        }
        let end = Date().addingTimeInterval(seconds)
        while !done && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }
        client?.stop()
    }

    static func dump() throws {
        let store = try Store(path: Store.defaultPath())
        let now = Int.nowMinute()
        for sensor in store.sensors() {
            let day = store.series(sensor.id, from: now - 1440, to: now, bucketMinutes: 1)
            let last = store.lastMinute(sensor.id).map { "\(now - $0) min ago" } ?? "never"
            print("\(sensor.isMain ? "★" : " ") \(sensor.name) [\(sensor.model.displayName)] \(sensor.id.uuidString)")
            let since = store.firstMinute(sensor.id).map { Date(timeIntervalSince1970: TimeInterval($0 * 60)).formatted(date: .abbreviated, time: .omitted) } ?? "-"
            print("    \(store.sampleCount(sensor.id)) minutes stored since \(since), \(day.count) in last 24h, last \(last)")
        }
    }
}
