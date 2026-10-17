import Foundation
import SensorTrayCore

/// One sensor's line for the current window, ready to draw.
struct ChartSeries: Equatable {
    let id: UUID
    let points: [SeriesPoint]
    /// Parallel to `points`: a new number wherever data is missing for more
    /// than a few buckets, so lines break at gaps instead of bridging them.
    let segments: [Int]
}

/// Everything the chart needs for one window, computed off the main thread.
struct ChartSnapshot: Equatable {
    let window: ChartWindow
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
    @Published private(set) var snapshot: ChartSnapshot?
    /// Last 24 h per sensor at 10-minute resolution, for the card sparklines.
    @Published private(set) var sparklines: [UUID: [SeriesPoint]] = [:]

    private struct Request {
        let window: ChartWindow
        let sensors: [UUID]
    }

    private static let rangeKey = "chartRange"
    private let reader: Store?
    private let queue = DispatchQueue(label: "com.nuwan.sensor-tray.charts", qos: .userInitiated)
    private var sensorIDs: [UUID] = []
    private var inFlight = false
    private var pending: Request?

    init(reader: Store?) {
        self.reader = reader
        let saved = UserDefaults.standard.string(forKey: Self.rangeKey).flatMap(ChartRange.init(rawValue:))
        window = ChartWindow(range: saved ?? .day)
    }

    private var earliest: Int? { snapshot?.earliest }

    // MARK: Navigation

    func setSensors(_ ids: [UUID]) {
        guard ids != sensorIDs else { return }
        sensorIDs = ids
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
        pending = Request(window: window, sensors: sensorIDs)
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
    nonisolated private static func compute(_ request: Request, reader: Store) -> (ChartSnapshot, [UUID: [SeriesPoint]]) {
        let now = Int.nowMinute()
        let earliest = reader.earliestMinute()
        let window = request.window
        let span = window.span(now: now, earliest: earliest)
        let bucket = window.bucketMinutes(now: now, earliest: earliest)
        // Local UTC offset, so day buckets run midnight to midnight.
        let offset = TimeZone.current.secondsFromGMT() / 60

        let series = request.sensors.map { id -> ChartSeries in
            let points = reader.aggregate(id, from: span.lowerBound, to: span.upperBound, bucketMinutes: bucket, alignOffset: offset)
            return ChartSeries(id: id, points: points, segments: segments(points, bucket: bucket))
        }
        let snapshot = ChartSnapshot(window: window, span: span, bucketMinutes: bucket,
                                     showsBand: window.showsBand(now: now, earliest: earliest),
                                     series: series, earliest: earliest)

        var sparklines: [UUID: [SeriesPoint]] = [:]
        for id in request.sensors {
            sparklines[id] = reader.aggregate(id, from: now - 1440, to: now, bucketMinutes: 10)
        }
        return (snapshot, sparklines)
    }

    nonisolated private static func segments(_ points: [SeriesPoint], bucket: Int) -> [Int] {
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
