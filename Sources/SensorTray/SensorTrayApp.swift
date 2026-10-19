import AppKit
import SensorTrayCore
import SwiftUI

struct SensorTrayApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environmentObject(model)
                .environmentObject(model.charts)
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

/// How the menu bar shows indoor and outdoor readings together.
enum MenuBarLayout: String, CaseIterable, Identifiable {
    /// Indoor on the top line, outdoor below, in aligned columns. Narrowest.
    case stacked
    /// A column per sensor: icon and humidity in small type over the
    /// temperature, like the CPU/RAM stats in many menu bar apps.
    case columns
    /// `⌂ 26.5° 63%  🌳 27.9° 54%` in full-size type. Widest.
    case sideBySide

    var id: String { rawValue }
    static let key = "menuBarLayout"

    var title: String {
        switch self {
        case .stacked: return "Stacked"
        case .columns: return "Columns"
        case .sideBySide: return "Side by side"
        }
    }

    var caption: String {
        switch self {
        case .stacked: return "Indoor above outdoor"
        case .columns: return "Humidity above temperature"
        case .sideBySide: return "Full size, widest"
        }
    }
}

/// The status item: the main sensor's temperature and humidity, plus the
/// outdoor sensor's when one is marked. Rendered to a template image so each
/// reading can be dimmed on its own when stale (MenuBarExtra labels ignore
/// opacity on plain Text).
struct MenuBarLabel: View {
    @ObservedObject var model: AppModel
    @AppStorage(MenuBarLayout.key) private var layout: MenuBarLayout = .stacked

    var body: some View {
        Image(nsImage: Self.render(parts: parts, layout: layout))
    }

    struct Part: Equatable {
        let symbol: String
        let temperature: String
        let humidity: String
        let dimmed: Bool

        init(symbol: String, reading: Reading?, dimmed: Bool) {
            self.symbol = symbol
            temperature = reading.map { String(format: "%.1f°", $0.tempC) } ?? "--"
            humidity = reading.map { String(format: "%.0f%%", $0.humidity) } ?? "--"
            self.dimmed = dimmed
        }
    }

    private var parts: [Part] {
        guard let outdoor = model.outdoorSensor else {
            return [part(model.mainSensor, symbol: "thermometer.medium")]
        }
        let indoor = model.mainSensor.map { [part($0, symbol: "house.fill")] } ?? []
        return indoor + [part(outdoor, symbol: "tree.fill")]
    }

    private func part(_ sensor: SensorConfig?, symbol: String) -> Part {
        let live = sensor.flatMap { model.latest[$0.id] }
        return Part(symbol: symbol, reading: live?.reading, dimmed: live?.isStale ?? true)
    }

    @MainActor
    static func render(parts: [Part], layout: MenuBarLayout) -> NSImage {
        let content = Group {
            if parts.count < 2 || layout == .sideBySide {
                sideBySide(parts)
            } else if layout == .stacked {
                stacked(parts)
            } else {
                columns(parts)
            }
        }
        .foregroundStyle(.black)
        .fixedSize()
        let renderer = ImageRenderer(content: content)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        let image = renderer.nsImage ?? NSImage()
        image.isTemplate = true
        return image
    }

    private static func sideBySide(_ parts: [Part]) -> some View {
        HStack(spacing: 9) {
            ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                HStack(spacing: 3) {
                    Image(systemName: part.symbol)
                        .font(.system(size: parts.count > 1 ? 11 : 12, weight: .medium))
                    Text(part.temperature + "  " + part.humidity)
                        .font(.system(size: 13, weight: .medium).monospacedDigit())
                }
                .opacity(part.dimmed ? 0.45 : 1)
            }
        }
    }

    /// Two 10.5 pt lines in a grid, so the digits line up; fits the 22 pt bar.
    private static func stacked(_ parts: [Part]) -> some View {
        Grid(alignment: .trailing, horizontalSpacing: 3, verticalSpacing: -2) {
            ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                GridRow {
                    Image(systemName: part.symbol)
                        .font(.system(size: 8, weight: .bold))
                        .gridColumnAlignment(.center)
                    Text(part.temperature)
                    Text(part.humidity)
                }
                .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                .opacity(part.dimmed ? 0.45 : 1)
            }
        }
        .frame(height: 22)
    }

    private static func columns(_ parts: [Part]) -> some View {
        HStack(spacing: 8) {
            ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                VStack(alignment: .leading, spacing: -2) {
                    HStack(spacing: 2) {
                        Image(systemName: part.symbol).font(.system(size: 7, weight: .bold))
                        Text(part.humidity).font(.system(size: 8.5, weight: .semibold).monospacedDigit())
                    }
                    Text(part.temperature)
                        .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                }
                .opacity(part.dimmed ? 0.45 : 1)
            }
        }
        .frame(height: 22)
    }
}
