import Foundation

/// How much time the chart shows at once.
public enum ChartRange: String, CaseIterable, Identifiable, Sendable {
    case sixHours = "6H", day = "24H", week = "7D", month = "30D", year = "1Y", all = "All"

    public var id: String { rawValue }

    /// Window length; nil for `.all`, which spans whatever history exists.
    public var lengthMinutes: Int? {
        switch self {
        case .sixHours: return 6 * 60
        case .day: return 1440
        case .week: return 7 * 1440
        case .month: return 30 * 1440
        case .year: return 365 * 1440
        case .all: return nil
        }
    }
}

/// One aggregated chart point: a bucket's average plus its extremes.
public struct SeriesPoint: Equatable, Sendable {
    /// First minute of the bucket (unix minutes).
    public var minute: Int
    /// Raw minute readings that fell in the bucket.
    public var count: Int
    public var tempAvg: Double
    public var tempMin: Double
    public var tempMax: Double
    public var humAvg: Double
    public var humMin: Double
    public var humMax: Double

    public init(minute: Int, count: Int, tempAvg: Double, tempMin: Double, tempMax: Double,
                humAvg: Double, humMin: Double, humMax: Double) {
        self.minute = minute
        self.count = count
        self.tempAvg = tempAvg
        self.tempMin = tempMin
        self.tempMax = tempMax
        self.humAvg = humAvg
        self.humMin = humMin
        self.humMax = humMax
    }

    public var date: Date { Date(timeIntervalSince1970: TimeInterval(minute * 60)) }
}

/// The slice of time the chart shows: a range length plus where it ends.
/// Pure value logic (no clock, no I/O) so it's directly testable; callers
/// pass `now` and the earliest stored minute.
public struct ChartWindow: Equatable, Sendable {
    /// Upper bound on points per sensor line, whatever the zoom level.
    public static let maxPoints = 400
    /// Bucket sizes `.all` can use, smallest first (day … 30 days).
    static let allBuckets = [1440, 2 * 1440, 7 * 1440, 14 * 1440, 30 * 1440]

    public var range: ChartRange
    /// Right edge in unix minutes; nil follows the present ("live").
    public var end: Int?

    public init(range: ChartRange, end: Int? = nil) {
        self.range = range
        self.end = end
    }

    public var isLive: Bool { end == nil }

    /// Minutes covered, inclusive.
    public func span(now: Int, earliest: Int?) -> ClosedRange<Int> {
        if let length = range.lengthMinutes {
            let right = end ?? now
            return (right - length)...right
        }
        // At least a day, so a brand-new install still gets a sensible axis.
        let start = min(earliest ?? now, now - 1440)
        return start...now
    }

    /// Bucket size that keeps every line at or under `maxPoints`.
    public func bucketMinutes(now: Int, earliest: Int?) -> Int {
        switch range {
        case .sixHours: return 1       // 360
        case .day: return 5            // 288
        case .week: return 30          // 336
        case .month: return 120        // 360
        case .year: return 1440        // 365
        case .all:
            let span = span(now: now, earliest: earliest)
            let length = span.upperBound - span.lowerBound
            return Self.allBuckets.first { length / $0 <= Self.maxPoints } ?? Self.allBuckets.last!
        }
    }

    /// Day-or-coarser buckets draw a min–max band behind the average line.
    public func showsBand(now: Int, earliest: Int?) -> Bool {
        bucketMinutes(now: now, earliest: earliest) >= 1440
    }

    /// Earliest allowed right edge: the window starting at the first reading.
    private func minimumEnd(now: Int, earliest: Int?) -> Int? {
        guard let length = range.lengthMinutes else { return nil }
        return (earliest ?? now) + length
    }

    public func canPanBack(now: Int, earliest: Int?) -> Bool {
        guard let minEnd = minimumEnd(now: now, earliest: earliest) else { return false }
        return (end ?? now) > minEnd
    }

    public func canPanForward(now: Int) -> Bool { range.lengthMinutes != nil && !isLive }

    /// Moves the window by `minutes` (negative = back in time), clamped to
    /// the stored history; reaching the present switches back to live.
    public func panned(by minutes: Int, now: Int, earliest: Int?) -> ChartWindow {
        guard let minEnd = minimumEnd(now: now, earliest: earliest) else { return self }
        let target = (end ?? now) + minutes
        if target >= now || minEnd >= now { return ChartWindow(range: range, end: nil) }
        return ChartWindow(range: range, end: max(target, minEnd))
    }

    /// Same right edge, different length (clamped so it stays valid).
    public func withRange(_ newRange: ChartRange, now: Int, earliest: Int?) -> ChartWindow {
        ChartWindow(range: newRange, end: newRange == .all ? nil : end).panned(by: 0, now: now, earliest: earliest)
    }
}
