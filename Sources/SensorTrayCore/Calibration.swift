import Foundation

/// A correction for one quantity (°C or %RH) of one sensor:
/// `corrected = x + offset + slope · (clamp(x) − pivot)`.
///
/// `slope` is how the error changes with the reading (0 for a constant
/// offset). Outside the range the fit was made over (`low…high`) the
/// correction holds at its edge value rather than extrapolating the slope.
public struct LinearCorrection: Codable, Equatable, Sendable {
    public var offset: Double
    public var slope: Double
    public var pivot: Double
    public var low: Double
    public var high: Double

    public init(offset: Double, slope: Double = 0, pivot: Double = 0, low: Double = 0, high: Double = 0) {
        self.offset = offset
        self.slope = slope
        self.pivot = pivot
        self.low = low
        self.high = high
    }

    public static let identity = LinearCorrection(offset: 0)

    /// The amount added to a raw reading `x`.
    public func delta(at x: Double) -> Double {
        offset + slope * (min(max(x, low), high) - pivot)
    }

    public func apply(_ x: Double) -> Double { x + delta(at: x) }

    public var isConstant: Bool { slope == 0 }
}

/// One 10-minute bucket where both sensors had readings: the sensor being
/// corrected (`raw…`) and the reference it should match (`ref…`).
public struct CalibrationPair: Equatable, Sendable {
    public let minute: Int
    public let rawTemp: Double
    public let rawHumidity: Double
    public let refTemp: Double
    public let refHumidity: Double

    public init(minute: Int, rawTemp: Double, rawHumidity: Double, refTemp: Double, refHumidity: Double) {
        self.minute = minute
        self.rawTemp = rawTemp
        self.rawHumidity = rawHumidity
        self.refTemp = refTemp
        self.refHumidity = refHumidity
    }
}

/// The fitted corrections for a sensor, plus what they were fitted on.
public struct CalibrationFit: Codable, Equatable, Sendable {
    public var temperature: LinearCorrection
    public var humidity: LinearCorrection
    /// 10-minute buckets used after dropping outliers.
    public var pairs: Int
    /// Typical remaining difference after correction (RMS), °C and %RH.
    public var temperatureError: Double
    public var humidityError: Double

    public init(temperature: LinearCorrection, humidity: LinearCorrection, pairs: Int,
                temperatureError: Double, humidityError: Double) {
        self.temperature = temperature
        self.humidity = humidity
        self.pairs = pairs
        self.temperatureError = temperatureError
        self.humidityError = humidityError
    }

    public func apply(_ reading: Reading) -> Reading {
        Reading(tempC: temperature.apply(reading.tempC),
                humidity: min(max(humidity.apply(reading.humidity), 0), 100),
                battery: reading.battery)
    }
}

/// Fits a sensor's readings to a reference's from periods when the two sat
/// side by side.
///
/// For each quantity the difference `ref − raw` is modelled as a line in the
/// raw value. A first, outlier-proof line (Theil–Sen: the median of pairwise
/// slopes) flags pairs further than 3 robust standard deviations
/// (1.4826 × MAD) from it; those are dropped and the final line is fitted to
/// the rest by least squares. (Starting from least squares instead would let
/// one far-off reading tilt the line towards itself.)
/// A slope is only fitted when the readings span enough of a range for it to
/// mean something (`minimumSpan`); otherwise the correction is the median
/// difference, a constant offset. The slope is limited to ±`maxSlope`
/// (a sensor whose error changes faster than that is faulty, not miscalibrated).
public enum Calibrator {
    /// Fewest 10-minute pairs accepted: one hour side by side.
    public static let minimumPairs = 6
    public static let maxSlope = 0.2
    /// Range the raw readings must cover before a slope is fitted.
    public static let minimumTemperatureSpan = 3.0
    public static let minimumHumiditySpan = 10.0

    public static func fit(_ pairs: [CalibrationPair]) -> CalibrationFit? {
        guard pairs.count >= minimumPairs else { return nil }
        let (temperature, tempError, tempUsed) = fitLine(x: pairs.map(\.rawTemp), y: pairs.map(\.refTemp),
                                                         minimumSpan: minimumTemperatureSpan)
        let (humidity, humError, _) = fitLine(x: pairs.map(\.rawHumidity), y: pairs.map(\.refHumidity),
                                              minimumSpan: minimumHumiditySpan)
        return CalibrationFit(temperature: temperature, humidity: humidity, pairs: tempUsed,
                              temperatureError: tempError, humidityError: humError)
    }

    /// Fits `y − x = offset + slope · (x − pivot)`. Returns the correction,
    /// the RMS residual, and how many points were kept.
    static func fitLine(x: [Double], y: [Double], minimumSpan: Double) -> (LinearCorrection, Double, Int) {
        let d = zip(x, y).map { $1 - $0 }
        var keep = Array(repeating: true, count: x.count)
        var correction = robustLine(x: x, d: d, minimumSpan: minimumSpan)

        // Outlier rejection against the robust line, then a least-squares refit.
        let residuals = d.indices.map { d[$0] - correction.delta(at: x[$0]) }
        let mad = median(residuals.map { abs($0 - median(residuals)) })
        let limit = max(3 * 1.4826 * mad, 0.05)
        keep = residuals.map { abs($0) <= limit }
        if keep.filter({ $0 }).count < minimumPairs {
            keep = Array(repeating: true, count: x.count)
        }
        correction = line(x: x, d: d, keep: keep, minimumSpan: minimumSpan)

        let kept = d.indices.filter { keep[$0] }
        let sumSquares = kept.reduce(0.0) { sum, i in
            let r = d[i] - correction.delta(at: x[i])
            return sum + r * r
        }
        return (correction, (sumSquares / Double(max(kept.count, 1))).squareRoot(), kept.count)
    }

    /// Theil–Sen: median slope over pairs of points (sampled down to 300
    /// points, so weeks of data stay cheap), and the median intercept.
    private static func robustLine(x: [Double], d: [Double], minimumSpan: Double) -> LinearCorrection {
        guard let low = x.min(), let high = x.max() else { return .identity }
        let pivot = x.reduce(0, +) / Double(x.count)
        guard high - low >= minimumSpan else {
            return LinearCorrection(offset: median(d), slope: 0, pivot: pivot, low: low, high: high)
        }
        let stride = max(1, x.count / 300)
        let idx = Swift.stride(from: 0, to: x.count, by: stride).map { $0 }
        var slopes: [Double] = []
        slopes.reserveCapacity(idx.count * idx.count / 2)
        for a in idx.indices {
            for b in (a + 1)..<idx.count {
                let dx = x[idx[b]] - x[idx[a]]
                if abs(dx) >= 0.5 { slopes.append((d[idx[b]] - d[idx[a]]) / dx) }
            }
        }
        let slope = min(max(median(slopes), -maxSlope), maxSlope)
        let offset = median(d.indices.map { d[$0] - slope * (x[$0] - pivot) })
        return LinearCorrection(offset: offset, slope: slope, pivot: pivot, low: low, high: high)
    }

    private static func line(x: [Double], d: [Double], keep: [Bool], minimumSpan: Double) -> LinearCorrection {
        let xs = x.indices.filter { keep[$0] }.map { x[$0] }
        let ds = d.indices.filter { keep[$0] }.map { d[$0] }
        guard let low = xs.min(), let high = xs.max() else { return .identity }
        let pivot = xs.reduce(0, +) / Double(xs.count)

        guard high - low >= minimumSpan else {
            return LinearCorrection(offset: median(ds), slope: 0, pivot: pivot, low: low, high: high)
        }
        let meanD = ds.reduce(0, +) / Double(ds.count)
        var sxx = 0.0, sxd = 0.0
        for (xi, di) in zip(xs, ds) {
            sxx += (xi - pivot) * (xi - pivot)
            sxd += (xi - pivot) * (di - meanD)
        }
        let slope = min(max(sxx > 0 ? sxd / sxx : 0, -maxSlope), maxSlope)
        return LinearCorrection(offset: meanD, slope: slope, pivot: pivot, low: low, high: high)
    }

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}

/// A side-by-side period used for a calibration.
public struct CalibrationSession: Identifiable, Equatable, Sendable {
    public let id: Int
    public let start: Int
    public let end: Int
    /// Minutes skipped after `start` while the moved sensor settles.
    public let settle: Int

    public init(id: Int, start: Int, end: Int, settle: Int) {
        self.id = id
        self.start = start
        self.end = end
        self.settle = settle
    }
}

/// A sensor's calibration against a reference sensor: its sessions and the
/// fit over all of them.
public struct SensorCalibration: Equatable, Sendable {
    public let sensor: UUID
    public let reference: UUID
    public var enabled: Bool
    public var fit: CalibrationFit?
    public var sessions: [CalibrationSession]

    public init(sensor: UUID, reference: UUID, enabled: Bool, fit: CalibrationFit?, sessions: [CalibrationSession]) {
        self.sensor = sensor
        self.reference = reference
        self.enabled = enabled
        self.fit = fit
        self.sessions = sessions
    }
}
