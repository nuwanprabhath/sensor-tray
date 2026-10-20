import Foundation

public enum CSV {
    /// Raw readings, plus calibrated columns when `calibration` is given.
    public static func render(_ points: [HistoryPoint], sensorName: String, calibration: CalibrationFit? = nil) -> String {
        let formatter = ISO8601DateFormatter()
        let name = escape(sensorName)
        var header = "timestamp,sensor,temperature_c,humidity_pct"
        if calibration != nil { header += ",temperature_c_calibrated,humidity_pct_calibrated" }
        var lines = [header]
        for p in points {
            var line = "\(formatter.string(from: p.date)),\(name),\(number(p.tempC)),\(number(p.humidity))"
            if let calibration {
                let c = calibration.apply(Reading(tempC: p.tempC, humidity: p.humidity, battery: nil))
                line += ",\(number(c.tempC)),\(number(c.humidity))"
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public static func renderAir(_ points: [AirPoint], sensorName: String) -> String {
        let formatter = ISO8601DateFormatter()
        let name = escape(sensorName)
        var lines = ["timestamp,sensor,pm25_ugm3,allergen_index"]
        for p in points {
            let date = Date(timeIntervalSince1970: TimeInterval(p.minute * 60))
            lines.append("\(formatter.string(from: date)),\(name),\(number(p.pmAvg)),\(number(p.iaiAvg))")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Two decimals max, no trailing zeros: 21.25, 48.5, 20.
    private static func number(_ value: Double) -> String {
        var s = String(format: "%.2f", value)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    private static func escape(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
