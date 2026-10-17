import AppKit
import SensorTrayCore
import SwiftUI

struct SensorTrayApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environmentObject(model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Window("Sensors", id: "sensors") {
            SensorsView()
                .environmentObject(model)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}

/// The status item: thermometer glyph + main sensor's temp and humidity.
/// Rendered to a template image so it can be dimmed when the data is stale
/// (MenuBarExtra labels ignore opacity on plain Text).
struct MenuBarLabel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Image(nsImage: Self.render(text: text, dimmed: dimmed))
    }

    private var live: LiveReading? { model.mainSensor.flatMap { model.latest[$0.id] } }
    private var dimmed: Bool { live?.isStale ?? true }

    private var text: String {
        guard let r = live?.reading else { return "--" }
        return String(format: "%.1f°  %.0f%%", r.tempC, r.humidity)
    }

    @MainActor
    static func render(text: String, dimmed: Bool) -> NSImage {
        let content = HStack(spacing: 3) {
            Image(systemName: "thermometer.medium")
                .font(.system(size: 12, weight: .medium))
            Text(text)
                .font(.system(size: 13, weight: .medium).monospacedDigit())
        }
        .foregroundStyle(.black)
        .opacity(dimmed ? 0.45 : 1)
        .fixedSize()
        let renderer = ImageRenderer(content: content)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        let image = renderer.nsImage ?? NSImage()
        image.isTemplate = true
        return image
    }
}
