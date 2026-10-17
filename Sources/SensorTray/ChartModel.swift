import Foundation
import SensorTrayCore

/// One bucket of the metric being charted: its average and range.
struct ChartPoint: Equatable {
    let minute: Int
    let avg: Double
    let low: Double
    let high: Double

    var date: Date { Date(timeIntervalSince1970: TimeInterval(minute * 60)) }
}

/// One sensor's line for the current window, ready to draw.
struct ChartSeries: Equatable {
    let id: UUID
    let points: [ChartPoint]
    /// Parallel to `points`: a new number wherever data is missing for more
    /// than a few buckets, so lines break at gaps instead of bridging them.
    let segments: [Int]
}

/// Everything the chart needs for one window, computed off the main thread.
struct ChartSnapshot: Equatable {
    let window: ChartWindow
    let metric: ChartMetric
    /// Minutes covered by the x axis.
    let span: ClosedRange<Int>
    let bucketMinutes: Int
    let showsBand: Bool
    let series: [ChartSeries]
    /// Oldest stored reading of any sensor; bounds panning.
    let earliest: Int?

    var isEmpty: Bool { series.allSatisfy(\.points.isEmpty) }
}

/// The chart's state (which window of time is shown) and its data loading.
///
/// Data is loaded on a background queue through a separate read-only SQLite
/// connection, so neither long ranges nor hovering block the UI. Requests
/// coalesce: while one query runs, newer requests replace each other and
/// only the most recent runs next. Dragging through months fires dozens of
/// requests, but the database sees only a handful. Each load is bounded at
/// `ChartWindow.maxPoints` per sensor, however much history is stored.
///
/// A reference type on purpose: pan/scroll handlers held by views and event
/// monitors always act on the current window, never a stale copy.
@MainActor
final class ChartModel: ObservableObject {
    @Published private(set) var window: ChartWindow
    @Published private(set) var metric: ChartMetric
    @Published private(set) var snapshot: ChartSnapshot?
    /// Last 24 h per sensor at 10-minute resolution, for the card sparklines
    /// (temperature for thermometers, PM2.5 for purifiers).
    @Published private(set) var sparklines: [UUID: [ChartPoint]] = [:]

    struct SensorRef: Equatable {
        let id: UUID
        let isAirPurifier: Bool
    }

    private struct Request {
        let window: ChartWindow
        let metric: ChartMetric
        let sensors: [SensorRef]
    }

    private static let rangeKey = "chartRange"
    private static let metricKey = "chartMetric"
    private let reader: Store?
    private let queue = DispatchQueue(label: "com.nuwan.sensor-tray.charts", qos: .userInitiated)
    private var sensors: [SensorRef] = []
    private var inFlight = false
    private var pending: Request?

    init(reader: Store?) {
        self.reader = reader
        let saved = UserDefaults.standard.string(forKey: Self.rangeKey).flatMap(ChartRange.init(rawValue:))
        window = ChartWindow(range: saved ?? .day)
        metric = UserDefaults.standard.string(forKey: Self.metricKey).flatMap(ChartMetric.init(rawValue:)) ?? .temperature
    }

    private var earliest: Int? { snapshot?.earliest }

    // MARK: Navigation

    func setSensors(_ configs: [SensorConfig]) {
        let refs = configs.map { SensorRef(id: $0.id, isAirPurifier: $0.model.isAirPurifier) }
        guard refs != sensors else { return }
        sensors = refs
        // PM2.5 needs a purifier; fall back if the last one was removed.
        if metric == .pm25 && !refs.contains(where: \.isAirPurifier) { metric = .temperature }
        reload()
    }

    func setMetric(_ newMetric: ChartMetric, persist: Bool = true) {
        if persist { UserDefaults.standard.set(newMetric.rawValue, forKey: Self.metricKey) }
        guard newMetric != metric else { return }
        metric = newMetric
        reload()
    }

    func setRange(_ range: ChartRange, persist: Bool = true) {
        if persist { UserDefaults.standard.set(range.rawValue, forKey: Self.rangeKey) }
        update(window.withRange(range, now: Int.nowMinute(), earliest: earliest))
    }

    /// Negative = back in time. Clamped to stored history; reaching the
    /// present switches back to following live data.
    func pan(by minutes: Int) {
        update(window.panned(by: minutes, now: Int.nowMinute(), earliest: earliest))
    }

    /// Steps a whole window length back (-1) or forward (+1).
    func step(_ direction: Int) {
        guard let length = window.range.lengthMinutes else { return }
        pan(by: direction * length)
    }

    func goLive() {
        update(ChartWindow(range: window.range))
    }

    var canStepBack: Bool { window.canPanBack(now: Int.nowMinute(), earliest: earliest) }
    var canStepForward: Bool { window.canPanForward(now: Int.nowMinute()) }

    private func update(_ newWindow: ChartWindow) {
        guard newWindow != window else { return }
        window = newWindow
        reload()
    }

    // MARK: Loading

    /// Re-queries the current window and the sparklines (e.g. new readings).
    func reload() {
        pending = Request(window: window, metric: metric, sensors: sensors)
        startNext()
    }

    private func startNext() {
        guard !inFlight, let request = pending, let reader else { return }
        pending = nil
        inFlight = true
        queue.async { [weak self] in
            let (snapshot, sparklines) = Self.compute(request, reader: reader)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.inFlight = false
                    if self.snapshot != snapshot { self.snapshot = snapshot }
                    if self.sparklines != sparklines { self.sparklines = sparklines }
                    self.startNext()
                }
            }
        }
    }

    /// Runs on the background queue.
    nonisolated private static func compute(_ request: Request, reader: Store) -> (ChartSnapshot, [UUID: [ChartPoint]]) {
        let now = Int.nowMinute()
        let earliest = reader.earliestMinute()
        let window = request.window
        let span = window.span(now: now, earliest: earliest)
        let bucket = window.bucketMinutes(now: now, earliest: earliest)
        // Local UTC offset, so day buckets run midnight to midnight.
        let offset = TimeZone.current.secondsFromGMT() / 60

        // Thermometers chart temperature/humidity; purifiers chart PM2.5.
        let charted = request.sensors.filter { $0.isAirPurifier == (request.metric == .pm25) }
        let series = charted.map { sensor -> ChartSeries in
            let points = points(for: sensor, metric: request.metric, reader: reader,
                                from: span.lowerBound, to: span.upperBound, bucket: bucket, offset: offset)
            return ChartSeries(id: sensor.id, points: points, segments: segments(points, bucket: bucket))
        }
        let snapshot = ChartSnapshot(window: window, metric: request.metric, span: span, bucketMinutes: bucket,
                                     showsBand: window.showsBand(now: now, earliest: earliest),
                                     series: series, earliest: earliest)

        var sparklines: [UUID: [ChartPoint]] = [:]
        for sensor in request.sensors {
            sparklines[sensor.id] = points(for: sensor, metric: sensor.isAirPurifier ? .pm25 : .temperature, reader: reader,
                                           from: now - 1440, to: now, bucket: 10, offset: 0)
        }
        return (snapshot, sparklines)
    }

    nonisolated private static func points(for sensor: SensorRef, metric: ChartMetric, reader: Store,
                                           from: Int, to: Int, bucket: Int, offset: Int) -> [ChartPoint] {
        if sensor.isAirPurifier {
            return reader.aggregateAir(sensor.id, from: from, to: to, bucketMinutes: bucket, alignOffset: offset)
                .map { ChartPoint(minute: $0.minute, avg: $0.pmAvg, low: $0.pmMin, high: $0.pmMax) }
        }
        let climate = reader.aggregate(sensor.id, from: from, to: to, bucketMinutes: bucket, alignOffset: offset)
        switch metric {
        case .humidity: return climate.map { ChartPoint(minute: $0.minute, avg: $0.humAvg, low: $0.humMin, high: $0.humMax) }
        default: return climate.map { ChartPoint(minute: $0.minute, avg: $0.tempAvg, low: $0.tempMin, high: $0.tempMax) }
        }
    }

    nonisolated private static func segments(_ points: [ChartPoint], bucket: Int) -> [Int] {
        var result: [Int] = []
        result.reserveCapacity(points.count)
        var segment = 0
        var previous: Int?
        for p in points {
            if let previous, p.minute - previous > bucket * 3 { segment += 1 }
            previous = p.minute
            result.append(segment)
        }
        return result
    }
}
