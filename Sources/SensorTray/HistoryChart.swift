import Charts
import SensorTrayCore
import SwiftUI

enum ChartMetric: String, CaseIterable, Identifiable {
    case temperature, humidity

    var id: String { rawValue }
    var symbol: String { self == .temperature ? "thermometer.medium" : "humidity" }
    var title: String { self == .temperature ? "Temperature" : "Humidity" }
    func value(_ p: HistoryPoint) -> Double { self == .temperature ? p.tempC : p.humidity }
    func format(_ v: Double) -> String { self == .temperature ? String(format: "%.1f°C", v) : String(format: "%.0f%%", v) }
    /// Axis ticks: drop the decimal when the tick is whole (24°C, not 24.0°C).
    func axisFormat(_ v: Double) -> String {
        let whole = v.rounded() == v
        switch self {
        case .temperature: return String(format: whole ? "%.0f°C" : "%.1f°C", v)
        case .humidity: return String(format: whole ? "%.0f%%" : "%.1f%%", v)
        }
    }
}

/// All sensors on one chart for the chosen metric and range, with a hover
/// rule that reads out every sensor's value at that time.
struct HistoryChart: View {
    @EnvironmentObject private var model: AppModel
    let range: ChartRange
    let metric: ChartMetric

    @StateObject private var hover = ViewState<Date?>(nil)

    private struct Line: Identifiable {
        let sensor: SensorConfig
        let color: Color
        let points: [HistoryPoint]
        var id: UUID { sensor.id }
    }

    private struct Plotted: Identifiable {
        let name: String
        let segment: String
        let date: Date
        let value: Double
        var id: String { "\(segment)-\(date.timeIntervalSince1970)" }
    }

    var body: some View {
        let lines = loadLines()
        let plotted = flatten(lines)

        if plotted.isEmpty {
            VStack(spacing: 4) {
                Image(systemName: "chart.xyaxis.line").foregroundStyle(.tertiary)
                Text("No history yet").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Chart {
                ForEach(plotted) { p in
                    LineMark(x: .value("Time", p.date), y: .value(metric.title, p.value), series: .value("Segment", p.segment))
                        .foregroundStyle(by: .value("Sensor", p.name))
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 1.8, lineCap: .round))
                }
                if let hoverDate = hover.value {
                    RuleMark(x: .value("Time", hoverDate))
                        .foregroundStyle(.secondary.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .annotation(position: .top, spacing: 0, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                            tooltip(at: hoverDate, lines: lines)
                        }
                }
            }
            .chartForegroundStyleScale(domain: lines.map(\.sensor.name), range: lines.map(\.color))
            .chartLegend(.hidden)
            .chartYScale(domain: .automatic(includesZero: false))
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine(stroke: Self.gridStroke).foregroundStyle(Self.gridColor)
                    AxisValueLabel {
                        if let v = value.as(Double.self) { Text(metric.axisFormat(v)).font(.system(size: 9)) }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine(stroke: Self.gridStroke).foregroundStyle(Self.gridColor)
                    // A label centered on a tick near the right edge gets
                    // clipped; hang those to the left of their tick instead.
                    if let date = value.as(Date.self), domain.upperBound.timeIntervalSince(date) < Double(range.minutes) * 60 * 0.08 {
                        AxisValueLabel(format: xFormat, anchor: .topTrailing).font(.system(size: 9))
                    } else {
                        AxisValueLabel(format: xFormat).font(.system(size: 9))
                    }
                }
            }
            .chartXScale(domain: domain)
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                guard let frame = proxy.plotFrame else { return }
                                let x = location.x - geo[frame].origin.x
                                hover.value = proxy.value(atX: x, as: Date.self)
                            case .ended:
                                hover.value = nil
                            }
                        }
                }
            }
        }
    }

    /// The whole selected range, so the axis doesn't shrink to the data.
    private var domain: ClosedRange<Date> {
        let now = Date()
        return now.addingTimeInterval(-Double(range.minutes) * 60)...now
    }

    private static let gridStroke = StrokeStyle(lineWidth: 0.7)
    private static let gridColor = Color.primary.opacity(0.22)

    private var xFormat: Date.FormatStyle {
        switch range {
        case .sixHours, .day: return .dateTime.hour()
        case .week: return .dateTime.weekday(.abbreviated)
        case .month: return .dateTime.day().month(.abbreviated)
        }
    }

    private func loadLines() -> [Line] {
        _ = model.dataVersion
        return model.sensors.map { sensor in
            Line(sensor: sensor, color: model.color(for: sensor), points: model.series(sensor.id, range: range))
        }
    }

    /// Splits each sensor's line where data is missing (Mac asleep, out of
    /// range) so the chart doesn't draw a misleading straight bridge.
    private func flatten(_ lines: [Line]) -> [Plotted] {
        var out: [Plotted] = []
        let maxGap = range.bucketMinutes * 3
        for line in lines {
            var segment = 0
            var previous: Int?
            for p in line.points {
                if let previous, p.minute - previous > maxGap { segment += 1 }
                previous = p.minute
                out.append(Plotted(name: line.sensor.name, segment: "\(line.sensor.id)-\(segment)",
                                   date: p.date, value: metric.value(p)))
            }
        }
        return out
    }

    private func tooltip(at date: Date, lines: [Line]) -> some View {
        let minute = Int(date.timeIntervalSince1970) / 60
        return VStack(alignment: .leading, spacing: 2) {
            Text(date, format: range == .sixHours || range == .day
                 ? .dateTime.hour().minute()
                 : .dateTime.weekday(.abbreviated).day().hour().minute())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
            ForEach(lines) { line in
                if let nearest = line.points.min(by: { abs($0.minute - minute) < abs($1.minute - minute) }),
                   abs(nearest.minute - minute) <= range.bucketMinutes * 2 {
                    HStack(spacing: 4) {
                        Circle().fill(line.color).frame(width: 6, height: 6)
                        Text(line.sensor.name).lineLimit(1)
                        Spacer(minLength: 6)
                        Text(metric.format(metric.value(nearest))).monospacedDigit()
                    }
                    .font(.system(size: 10))
                }
            }
        }
        .padding(6)
        .frame(width: 150)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
    }
}
