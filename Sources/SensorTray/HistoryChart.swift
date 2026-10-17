import AppKit
import Charts
import SensorTrayCore
import SwiftUI

enum ChartMetric: String, CaseIterable, Identifiable {
    case temperature, humidity

    var id: String { rawValue }
    var symbol: String { self == .temperature ? "thermometer.medium" : "humidity" }
    var title: String { self == .temperature ? "Temperature" : "Humidity" }
    func average(_ p: SeriesPoint) -> Double { self == .temperature ? p.tempAvg : p.humAvg }
    func low(_ p: SeriesPoint) -> Double { self == .temperature ? p.tempMin : p.humMin }
    func high(_ p: SeriesPoint) -> Double { self == .temperature ? p.tempMax : p.humMax }
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

/// How a sensor's line looks; kept apart from the data so renames and
/// recolors don't need a reload.
struct SeriesStyle: Equatable {
    let id: UUID
    let name: String
    let color: Color
}

/// All sensors over the loaded window: an average line per sensor, plus a
/// shaded daily min–max band at day-or-coarser resolution (1Y / All).
///
/// Equatable, so SwiftUI only re-renders the marks when the data, metric or
/// styles change. Hover, drag-to-pan and trackpad swipes live in
/// `ChartInteractionLayer`, whose state changes never touch the marks.
struct HistoryChart: View, Equatable {
    let snapshot: ChartSnapshot
    let metric: ChartMetric
    let styles: [SeriesStyle]
    /// Navigation target for drags and swipes (a reference, so never stale).
    let charts: ChartModel

    static func == (lhs: HistoryChart, rhs: HistoryChart) -> Bool {
        lhs.snapshot == rhs.snapshot && lhs.metric == rhs.metric && lhs.styles == rhs.styles
    }

    private struct Mark: Identifiable {
        let id: Int
        let sensor: String
        let segment: String
        let date: Date
        let value: Double
        let low: Double
        let high: Double
    }

    var body: some View {
        if snapshot.isEmpty {
            VStack(spacing: 4) {
                Image(systemName: "chart.xyaxis.line").foregroundStyle(.tertiary)
                Text(snapshot.window.isLive ? "No history yet" : "No readings in this period")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            // Still draggable, so an empty stretch can be scrolled past.
            .overlay { ChartInteractionLayer(proxy: nil, snapshot: snapshot, metric: metric, styles: [], charts: charts) }
        } else {
            chart
        }
    }

    private var chart: some View {
        let marks = buildMarks()
        let domain = Self.date(snapshot.span.lowerBound)...Self.date(snapshot.span.upperBound)
        let visible = styles.filter { style in snapshot.series.contains { $0.id == style.id } }

        return Chart {
            if snapshot.showsBand {
                ForEach(marks) { m in
                    AreaMark(x: .value("Time", m.date), yStart: .value("Low", m.low), yEnd: .value("High", m.high),
                             series: .value("Segment", m.segment))
                        .foregroundStyle(by: .value("Sensor", m.sensor))
                        .opacity(0.2)
                        .interpolationMethod(.monotone)
                }
            }
            ForEach(marks) { m in
                LineMark(x: .value("Time", m.date), y: .value(metric.title, m.value), series: .value("Segment", m.segment))
                    .foregroundStyle(by: .value("Sensor", m.sensor))
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: snapshot.showsBand ? 1.5 : 1.8, lineCap: .round))
            }
        }
        .chartForegroundStyleScale(domain: visible.map(\.id.uuidString), range: visible.map(\.color))
        .chartLegend(.hidden)
        .chartXScale(domain: domain)
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
            AxisMarks(values: TimeTicks.ticks(in: domain)) { _ in
                AxisGridLine(stroke: Self.gridStroke).foregroundStyle(Self.gridColor)
                AxisValueLabel(format: xFormat).font(.system(size: 9))
            }
        }
        .chartOverlay { proxy in
            ChartInteractionLayer(proxy: proxy, snapshot: snapshot, metric: metric, styles: visible, charts: charts)
        }
    }

    private func buildMarks() -> [Mark] {
        var marks: [Mark] = []
        marks.reserveCapacity(snapshot.series.reduce(0) { $0 + $1.points.count })
        for series in snapshot.series {
            let sensor = series.id.uuidString
            for (i, p) in series.points.enumerated() {
                marks.append(Mark(id: marks.count, sensor: sensor, segment: "\(sensor)-\(series.segments[i])",
                                  date: p.date, value: metric.average(p), low: metric.low(p), high: metric.high(p)))
            }
        }
        return marks
    }

    private var xFormat: Date.FormatStyle {
        switch snapshot.span.upperBound - snapshot.span.lowerBound {
        case ..<(2 * 1440): return .dateTime.hour()
        case ..<(8 * 1440): return .dateTime.weekday(.abbreviated)
        case ..<(60 * 1440): return .dateTime.day().month(.abbreviated)
        case ..<(400 * 1440): return .dateTime.month(.abbreviated)
        default: return .dateTime.month(.abbreviated).year(.twoDigits)
        }
    }

    static func date(_ minute: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(minute * 60)) }

    private static let gridStroke = StrokeStyle(lineWidth: 0.7)
    private static let gridColor = Color.primary.opacity(0.22)
}

/// Hover read-out, drag-to-pan and horizontal trackpad scrolling.
/// Owns its own state so pointer movement re-renders only this layer.
private struct ChartInteractionLayer: View {
    let proxy: ChartProxy?
    let snapshot: ChartSnapshot
    let metric: ChartMetric
    let styles: [SeriesStyle]
    let charts: ChartModel

    @StateObject private var state = InteractionState()

    var body: some View {
        GeometryReader { geo in
            let plot = proxy.flatMap { p in p.plotFrame.map { geo[$0] } } ?? CGRect(origin: .zero, size: geo.size)
            ZStack(alignment: .topLeading) {
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location): state.hoverX = location.x - plot.minX
                        case .ended: state.hoverX = nil
                        }
                    }
                    .gesture(dragToPan)

                if let proxy, let x = state.hoverX, state.dragApplied == nil,
                   let minute = nearestBucket(atX: x, proxy: proxy),
                   let lineX = proxy.position(forX: HistoryChart.date(minute)) {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.6))
                        .frame(width: 1, height: plot.height)
                        .offset(x: plot.minX + lineX, y: plot.minY)
                    tooltip(minute: minute)
                        .fixedSize()
                        .alignmentGuide(.leading) { d in
                            // Right of the cursor when it fits, otherwise left; always inside the plot.
                            let right = plot.minX + lineX + 8
                            let x = right + d.width <= plot.maxX ? right : max(plot.minX, plot.minX + lineX - 8 - d.width)
                            return -x
                        }
                        .offset(y: plot.minY + 2)
                }
            }
            .onAppear {
                state.plotWidth = plot.width
                state.installScrollMonitor(charts: charts)
            }
            .onChange(of: plot.width) { _, width in state.plotWidth = width }
            .onDisappear { state.removeScrollMonitor() }
        }
    }

    /// Dragging right moves back in time, like pulling the timeline along.
    private var dragToPan: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                guard let minutes = state.minutes(forDeltaX: value.translation.width, charts: charts) else { return }
                let delta = minutes - (state.dragApplied ?? 0)
                state.dragApplied = minutes
                if delta != 0 { charts.pan(by: delta) }
            }
            .onEnded { _ in state.dragApplied = nil }
    }

    /// The bucket under the pointer, snapped to the bucket grid.
    private func nearestBucket(atX x: CGFloat, proxy: ChartProxy) -> Int? {
        guard let date: Date = proxy.value(atX: x) else { return nil }
        let minute = Int(date.timeIntervalSince1970 / 60)
        var best: Int?
        for series in snapshot.series {
            guard let p = Self.nearest(series.points, to: minute) else { continue }
            if best == nil || abs(p.minute - minute) < abs(best! - minute) { best = p.minute }
        }
        guard let best, abs(best - minute) <= snapshot.bucketMinutes * 2 else { return nil }
        return best
    }

    /// Binary search over points sorted by minute.
    static func nearest(_ points: [SeriesPoint], to minute: Int) -> SeriesPoint? {
        guard !points.isEmpty else { return nil }
        var low = 0, high = points.count - 1
        while low < high {
            let mid = (low + high) / 2
            if points[mid].minute < minute { low = mid + 1 } else { high = mid }
        }
        if low > 0, abs(points[low - 1].minute - minute) <= abs(points[low].minute - minute) { return points[low - 1] }
        return points[low]
    }

    private func tooltip(minute: Int) -> some View {
        let date = HistoryChart.date(minute)
        let daily = snapshot.bucketMinutes >= 1440
        return VStack(alignment: .leading, spacing: 2) {
            Text(date, format: daily ? .dateTime.weekday(.abbreviated).day().month(.abbreviated).year()
                                     : .dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
            ForEach(styles, id: \.id) { style in
                if let series = snapshot.series.first(where: { $0.id == style.id }),
                   let p = Self.nearest(series.points, to: minute), abs(p.minute - minute) <= snapshot.bucketMinutes {
                    HStack(spacing: 4) {
                        Circle().fill(style.color).frame(width: 6, height: 6)
                        Text(style.name).lineLimit(1)
                        Spacer(minLength: 6)
                        Text(metric.format(metric.average(p))).monospacedDigit()
                        if daily {
                            // The day's range, e.g. "18.2–24.9°C".
                            Text(String(format: "%.1f–", metric.low(p)) + metric.format(metric.high(p)))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.system(size: 10))
                }
            }
        }
        .padding(6)
        .frame(width: daily ? 220 : 150, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
    }
}

/// Pointer state for the chart overlay, plus the trackpad scroll monitor.
@MainActor
private final class InteractionState: ObservableObject {
    @Published var hoverX: CGFloat?
    /// Minutes already panned by the current drag (nil when not dragging).
    var dragApplied: Int?
    var plotWidth: CGFloat = 0
    private var scrollRemainder: CGFloat = 0
    private var monitor: Any?

    /// Converts a horizontal pointer distance into minutes of the current
    /// window (positive distance → back in time). Nil when not pannable.
    func minutes(forDeltaX dx: CGFloat, charts: ChartModel) -> Int? {
        guard plotWidth > 0, let span = charts.snapshot?.span, charts.window.range != .all else { return nil }
        return Int(-dx / plotWidth * CGFloat(span.upperBound - span.lowerBound))
    }

    /// Horizontal two-finger swipes over the chart pan it. SwiftUI has no
    /// scroll-wheel API on macOS 14, so this taps the app's own event stream.
    /// Vertical scrolls, and any scrolling while the pointer isn't over the
    /// chart, pass through untouched.
    func installScrollMonitor(charts: ChartModel) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self, weak charts] event in
            guard abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else { return event }
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, let charts, self.hoverX != nil,
                      let span = charts.snapshot?.span, self.plotWidth > 0, charts.window.range != .all else { return false }
                self.scrollRemainder += event.scrollingDeltaX / self.plotWidth * CGFloat(span.upperBound - span.lowerBound)
                let minutes = Int(self.scrollRemainder)
                self.scrollRemainder -= CGFloat(minutes)
                // Natural scrolling: fingers moving right reveal earlier time.
                if minutes != 0 { charts.pan(by: -minutes) }
                return true
            }
            return handled ? nil : event
        }
    }

    func removeScrollMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }
}

/// Calendar-aligned x-axis ticks (every 2 h, 6 h, 2 days, week, quarter,
/// half-year or year, depending on span) that stay clear of the plot edges.
/// Charts' automatic ticks can land on the very edge, where a centered label
/// clips or an inward-anchored one collides with its neighbour.
enum TimeTicks {
    static func ticks(in domain: ClosedRange<Date>, calendar: Calendar = .current) -> [Date] {
        let length = domain.upperBound.timeIntervalSince(domain.lowerBound)
        guard length > 0 else { return [] }
        let day: TimeInterval = 86_400
        let (component, step): (Calendar.Component, Int)
        switch length {
        case ..<(0.5 * day): (component, step) = (.hour, 2)
        case ..<(2 * day): (component, step) = (.hour, 6)
        case ..<(8 * day): (component, step) = (.day, 2)
        case ..<(60 * day): (component, step) = (.day, 7)
        case ..<(400 * day): (component, step) = (.month, 3)
        case ..<(5 * 365 * day): (component, step) = (.month, 6)
        default: (component, step) = (.year, 1)
        }

        // First boundary at or before the domain start, aligned to the step
        // (e.g. 00/06/12/18 h, Jan/Apr/Jul/Oct).
        var start: Date
        switch component {
        case .hour:
            let hourStart = calendar.dateInterval(of: .hour, for: domain.lowerBound)!.start
            let hour = calendar.component(.hour, from: hourStart)
            start = calendar.date(byAdding: .hour, value: -(hour % step), to: hourStart)!
        case .day:
            start = calendar.startOfDay(for: domain.lowerBound)
        case .month:
            let monthStart = calendar.dateInterval(of: .month, for: domain.lowerBound)!.start
            let month = calendar.component(.month, from: monthStart) - 1
            start = calendar.date(byAdding: .month, value: -(month % step), to: monthStart)!
        default:
            start = calendar.dateInterval(of: .year, for: domain.lowerBound)!.start
        }

        var ticks: [Date] = []
        var tick = start
        while tick <= domain.upperBound, ticks.count < 50 {
            let fraction = tick.timeIntervalSince(domain.lowerBound) / length
            // Keep labels (centered on their tick) clear of both edges.
            if fraction >= 0.07 && fraction <= 0.9 { ticks.append(tick) }
            guard let next = calendar.date(byAdding: component, value: step, to: tick) else { break }
            tick = next
        }
        return ticks
    }
}
