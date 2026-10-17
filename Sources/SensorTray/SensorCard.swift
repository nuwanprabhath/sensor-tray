import SensorTrayCore
import SwiftUI

/// One sensor in the popover: name, big temperature, humidity, battery,
/// freshness, and a 24h temperature sparkline.
struct SensorCard: View {
    @EnvironmentObject private var model: AppModel
    let sensor: SensorConfig

    var body: some View {
        let live = model.latest[sensor.id]
        let color = model.color(for: sensor)
        let points = sparkPoints

        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Circle().fill(color).frame(width: 8, height: 8)
                    Text(sensor.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    if sensor.isMain && model.sensors.count > 1 {
                        Image(systemName: "star.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.yellow)
                            .help("Shown in the menu bar")
                    }
                }
                HStack(spacing: 6) {
                    status(live)
                    if let low = points.map(\.tempC).min(), let high = points.map(\.tempC).max() {
                        Text(String(format: "24h %.1f–%.1f°C", low, high))
                            .help("Lowest and highest temperature in the last 24 hours")
                    }
                    if let battery = live?.reading.battery {
                        BatteryBadge(percent: battery)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)

                Sparkline(points: points, color: color)
                    .frame(height: 22)
                    .padding(.top, 2)
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text(live.map { String(format: "%.1f", $0.reading.tempC) } ?? "--")
                        .font(.system(size: 30, weight: .medium, design: .rounded).monospacedDigit())
                    Text("°C")
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 3) {
                    Image(systemName: "drop.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.teal)
                    Text(live.map { String(format: "%.0f%%", $0.reading.humidity) } ?? "--")
                        .font(.system(size: 14, weight: .medium, design: .rounded).monospacedDigit())
                }
            }
            .foregroundStyle(live?.isStale ?? true ? .secondary : .primary)
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }

    private var sparkPoints: [HistoryPoint] {
        _ = model.dataVersion
        return model.series(sensor.id, range: .day)
    }

    @ViewBuilder
    private func status(_ live: LiveReading?) -> some View {
        if let live {
            if live.isStale {
                Label {
                    Text(live.at, format: .relative(presentation: .named))
                } icon: {
                    Image(systemName: "wifi.slash")
                }
                .labelStyle(.titleAndIcon)
            } else {
                Label("Live", systemImage: "dot.radiowaves.left.and.right")
                    .labelStyle(.titleAndIcon)
            }
        } else {
            Text("\(sensor.model.displayName) · waiting for data")
        }
    }
}

struct BatteryBadge: View {
    let percent: Int

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: symbol)
                .foregroundStyle(percent <= 15 ? Color.red : Color.secondary)
            Text("\(percent)%")
        }
        .help("Battery \(percent)%")
    }

    private var symbol: String {
        switch percent {
        case ..<15: return "battery.0percent"
        case ..<40: return "battery.25percent"
        case ..<65: return "battery.50percent"
        case ..<90: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}

/// Minimal line of the last 24h temperatures with a soft fill.
struct Sparkline: View {
    let points: [HistoryPoint]
    let color: Color

    var body: some View {
        GeometryReader { geo in
            if points.count > 1 {
                let path = linePath(in: geo.size)
                ZStack {
                    area(from: path, in: geo.size)
                        .fill(LinearGradient(colors: [color.opacity(0.25), color.opacity(0)], startPoint: .top, endPoint: .bottom))
                    path.stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                }
            } else {
                Rectangle()
                    .fill(color.opacity(0.15))
                    .frame(height: 1)
                    .frame(maxHeight: .infinity)
            }
        }
    }

    private func linePath(in size: CGSize) -> Path {
        let temps = points.map(\.tempC)
        let minT = temps.min() ?? 0
        let maxT = temps.max() ?? 1
        let spanT = max(maxT - minT, 0.5)      // flat lines stay flat, not noisy
        let minM = Double(points.first?.minute ?? 0)
        let spanM = max(Double((points.last?.minute ?? 1)) - minM, 1)
        var path = Path()
        for (i, p) in points.enumerated() {
            let x = (Double(p.minute) - minM) / spanM * size.width
            let y = size.height - 2 - (p.tempC - minT) / spanT * (size.height - 4)
            if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        return path
    }

    private func area(from line: Path, in size: CGSize) -> Path {
        var path = line
        path.addLine(to: CGPoint(x: size.width, y: size.height))
        path.addLine(to: CGPoint(x: 0, y: size.height))
        path.closeSubpath()
        return path
    }
}
