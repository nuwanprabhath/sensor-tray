import SensorTrayCore
import SwiftUI

/// PM2.5 bands (µg/m³, 24-hour US EPA breakpoints) for the card's colour and label.
enum AirQualityLevel {
    case good, fair, poor, veryPoor

    init(pm25: Int) {
        switch pm25 {
        case ...12: self = .good
        case ...35: self = .fair
        case ...55: self = .poor
        default: self = .veryPoor
        }
    }

    var title: String {
        switch self {
        case .good: return "Good"
        case .fair: return "Fair"
        case .poor: return "Poor"
        case .veryPoor: return "Very poor"
        }
    }

    var color: Color {
        switch self {
        case .good: return .green
        case .fair: return .yellow
        case .poor: return .orange
        case .veryPoor: return .red
        }
    }
}

/// An air purifier in the popover: PM2.5 with its air-quality level, the
/// allergen index, mode, filter state and a 24 h PM2.5 sparkline.
struct PurifierCard: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var charts: ChartModel
    let sensor: SensorConfig

    var body: some View {
        let live = model.air[sensor.id]
        let reading = live?.reading
        let color = model.color(for: sensor)
        let level = reading?.pm25.map(AirQualityLevel.init(pm25:))
        let points = charts.sparklines[sensor.id] ?? []

        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Circle().fill(color).frame(width: 8, height: 8)
                    Text(sensor.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Image(systemName: "wind")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .help("Air purifier")
                }
                HStack(spacing: 6) {
                    status(live)
                    if let mode = reading?.mode, reading?.isOn != false {
                        Text(mode)
                    } else if reading?.isOn == false {
                        Text("Off")
                    }
                    if let iai = reading?.allergenIndex {
                        Text("Allergens \(iai)/12")
                            .help("Indoor allergen index (1–12)")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)

                if let reading, reading.filterNeedsReplacing || reading.preFilterNeedsCleaning {
                    Label(reading.filterNeedsReplacing ? "Replace the filter" : "Clean the pre-filter",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(reading.filterNeedsReplacing ? .red : .orange)
                } else if let percent = reading?.filterPercentLeft {
                    Label("Filter \(percent)%", systemImage: "line.3.horizontal.decrease.circle")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Sparkline(points: points, color: color, minimumSpan: 5)
                    .frame(height: 22)
                    .padding(.top, 2)
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(reading?.pm25.map(String.init) ?? "--")
                        .font(.system(size: 30, weight: .medium, design: .rounded).monospacedDigit())
                    Text("µg/m³")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 4) {
                    Text("PM2.5")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    if let level {
                        Text(level.title)
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(level.color.opacity(0.22), in: Capsule())
                            .foregroundStyle(level.color)
                    }
                }
            }
            .foregroundStyle(live?.status == .reachable ? .primary : .secondary)
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func status(_ live: LiveAir?) -> some View {
        switch live?.status {
        case .reachable?:
            if live?.isFresh == true, let at = live?.updatedAt {
                // It only reports changes, so "updated 20 min ago" is normal in steady air.
                Label { Text(at, format: .relative(presentation: .named)) } icon: { Image(systemName: "wifi") }
                    .labelStyle(.titleAndIcon)
                    .help("The purifier reports when a value changes")
            } else {
                Label("Waiting for update", systemImage: "wifi")
                    .labelStyle(.titleAndIcon)
                    .help("Connected. The purifier sends data when a value changes, which can take a few minutes.")
            }
        case .unreachable?:
            Label("Offline", systemImage: "wifi.slash").labelStyle(.titleAndIcon)
        default:
            Label("Connecting", systemImage: "wifi").labelStyle(.titleAndIcon)
        }
    }
}
