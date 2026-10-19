import SensorTrayCore
import SwiftUI

/// One sensor in the popover: name, big temperature, humidity, battery,
/// freshness, and a temperature sparkline (last 24 h by default).
struct SensorCard: View {
    /// Shared by every card (purifiers too), so the sparklines all end at the
    /// same x and can be compared vertically.
    static let valueColumnWidth: CGFloat = 124

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var charts: ChartModel
    let sensor: SensorConfig

    var body: some View {
        let live = model.latest[sensor.id]
        let color = model.color(for: sensor)
        let points = charts.sparklines[sensor.id] ?? []

        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Circle().fill(color).frame(width: 8, height: 8)
                    Text(sensor.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    if sensor.isOutdoor {
                        Image(systemName: "tree.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.green)
                            .help("Outdoor sensor, shown in the menu bar")
                    } else if sensor.id == model.mainSensor?.id && model.sensors.count > 1 {
                        Image(systemName: "star.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.yellow)
                            .help("Shown in the menu bar")
                    }
                }
                HStack(spacing: 6) {
                    status(live)
                    if let low = points.map(\.low).min(), let high = points.map(\.high).max() {
                        let window = charts.sparkContext.window
                        Text(String(format: "\(window.title) %.1f–%.1f°C", low, high))
                            .help("Lowest and highest temperature in the last \(window.spoken)")
                    }
                    if let battery = live?.reading.battery {
                        BatteryBadge(percent: battery)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)

                Sparkline(points: points, color: color, context: charts.sparkContext)
                    .frame(height: 32)
                    .padding(.top, 2)
            }

            .frame(maxWidth: .infinity, alignment: .leading)

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
                if let comparison {
                    HStack(spacing: 3) {
                        Text(comparison.text)
                        Image(systemName: "tree.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.green)
                    }
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .frame(maxWidth: Self.valueColumnWidth, alignment: .trailing)
                    .padding(.top, 2)
                    .help(comparison.help)
                }
            }
            .foregroundStyle(live?.isStale ?? true ? .secondary : .primary)
            .frame(width: Self.valueColumnWidth, alignment: .trailing)
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }

    /// On every indoor thermometer card: indoor minus outdoor, so "+1.2°C"
    /// means it's 1.2° warmer in this room than outside.
    private var comparison: (text: String, help: String)? {
        guard !sensor.isOutdoor, let outdoor = model.outdoorSensor,
              let inside = model.latest[sensor.id]?.reading, let outside = model.latest[outdoor.id]?.reading else { return nil }
        let dt = Self.signed(inside.tempC - outside.tempC, decimals: 1)
        let dh = Self.signed(inside.humidity - outside.humidity, decimals: 0)
        return ("\(dt)°C  \(dh)% vs",
                "\(sensor.name) compared with \(outdoor.name): positive means warmer / more humid inside")
    }

    /// "+1.2", "−0.4", and "+0" rather than "-0" for differences that round to zero.
    static func signed(_ value: Double, decimals: Int) -> String {
        let scale = pow(10, Double(decimals))
        let rounded = (value * scale).rounded() / scale
        return String(format: "%+.\(decimals)f", rounded == 0 ? 0 : rounded)
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

/// Minimal line of recent history with a soft fill, on a fixed time axis
/// (the chosen window → now, labelled underneath) so a sensor that's only been
/// running for an hour fills only the last hour. Event markers show as
/// dashed lines, the focused one in the marker colour.
struct Sparkline: View {
    let points: [ChartPoint]
    let color: Color
    let context: ChartModel.SparkContext
    /// Smallest vertical range drawn, so small wobbles stay flat (0.5 °C; ~5 µg/m³ for PM2.5).
    var minimumSpan: Double = 0.5

    var body: some View {
        VStack(spacing: 1) {
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    // The time after the focused marker, as on the main chart.
                    if let focused = context.events.first(where: { $0.id == context.focusedEvent }) {
                        let start = x(focused.minute, width: geo.size.width)
                        Rectangle()
                            .fill(HistoryChart.markerColor.opacity(0.12))
                            .frame(width: max(geo.size.width - start, 1), height: geo.size.height)
                            .offset(x: start)
                    }
                    if points.count > 1 {
                        let path = linePath(in: geo.size)
                        area(from: path, in: geo.size)
                            .fill(LinearGradient(colors: [color.opacity(0.25), color.opacity(0)], startPoint: .top, endPoint: .bottom))
                        path.stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    } else {
                        Rectangle()
                            .fill(color.opacity(0.15))
                            .frame(height: 1)
                            .frame(maxHeight: .infinity)
                    }
                    ForEach(context.events) { event in
                        marker(event, in: geo.size)
                    }
                }
            }
            HStack {
                let labels = context.window.axisLabels
                Text(labels.0)
                Spacer()
                Text(labels.1)
                Spacer()
                Text(labels.2)
            }
            .font(.system(size: 8, weight: .medium).monospacedDigit())
            .foregroundStyle(.tertiary)
        }
    }

    private func marker(_ event: ChartEvent, in size: CGSize) -> some View {
        let focused = event.id == context.focusedEvent
        let markerColor = focused ? HistoryChart.markerColor : Color.primary.opacity(0.45)
        let x = x(event.minute, width: size.width)
        return ZStack(alignment: .topLeading) {
            Path { p in
                p.move(to: CGPoint(x: x, y: 0))
                p.addLine(to: CGPoint(x: x, y: size.height))
            }
            .stroke(markerColor, style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
            Image(systemName: "flag.fill")
                .font(.system(size: 6))
                .foregroundStyle(markerColor)
                .offset(x: min(x, size.width - 7), y: -3)
        }
        .help(event.label.isEmpty ? "Marker" : event.label)
    }

    private func x(_ minute: Int, width: CGFloat) -> CGFloat {
        let span = Double(max(context.span.upperBound - context.span.lowerBound, 1))
        return CGFloat(Double(minute - context.span.lowerBound) / span) * width
    }

    private func linePath(in size: CGSize) -> Path {
        let temps = points.map(\.avg)
        let minT = temps.min() ?? 0
        let maxT = temps.max() ?? 1
        let spanT = max(maxT - minT, minimumSpan)      // flat lines stay flat, not noisy
        var path = Path()
        for (i, p) in points.enumerated() {
            let px = x(p.minute, width: size.width)
            let y = size.height - 2 - (p.avg - minT) / spanT * (size.height - 4)
            if i == 0 { path.move(to: CGPoint(x: px, y: y)) } else { path.addLine(to: CGPoint(x: px, y: y)) }
        }
        return path
    }

    /// Fill under the line only where there is data.
    private func area(from line: Path, in size: CGSize) -> Path {
        var path = line
        let lastX = x(points.last?.minute ?? 0, width: size.width)
        let firstX = x(points.first?.minute ?? 0, width: size.width)
        path.addLine(to: CGPoint(x: lastX, y: size.height))
        path.addLine(to: CGPoint(x: firstX, y: size.height))
        path.closeSubpath()
        return path
    }
}
