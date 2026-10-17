import AppKit
import CoreBluetooth
import Foundation
import SwiftUI
import SensorTrayCore

// CLI escape hatches for testing the Bluetooth layer without the GUI:
//   SensorTray --scan [seconds]           list nearby Govee/ThermoPro sensors with live readings
//   SensorTray --history <uuid> [minutes] download a sensor's stored history (default 60 min)
//   SensorTray --dump                     print configured sensors and stored data ranges
//   SensorTray --snapshot <png> [light|dark] [sensors] render the popover (or Sensors window) with live data
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
        // Let a few advertisements arrive so the cards show live values.
        RunLoop.main.run(until: Date().addingTimeInterval(12))

        let root = Group {
            if arguments.contains("sensors") { SensorsView() } else { PopoverView() }
        }
            .environmentObject(model)
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

    static func dump() throws {
        let store = try Store(path: Store.defaultPath())
        let now = Int.nowMinute()
        for sensor in store.sensors() {
            let day = store.series(sensor.id, from: now - 1440, to: now, bucketMinutes: 1)
            let all = store.series(sensor.id, from: 0, to: now, bucketMinutes: 1)
            let last = store.lastMinute(sensor.id).map { "\(now - $0) min ago" } ?? "never"
            print("\(sensor.isMain ? "★" : " ") \(sensor.name) [\(sensor.model.displayName)] \(sensor.id.uuidString)")
            print("    \(all.count) points total, \(day.count) in last 24h, last \(last)")
        }
    }
}
