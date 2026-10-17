import Foundation

public enum CSV {
    public static func render(_ points: [HistoryPoint], sensorName: String) -> String {
        let formatter = ISO8601DateFormatter()
        let name = escape(sensorName)
        var lines = ["timestamp,sensor,temperature_c,humidity_pct"]
        for p in points {
            lines.append("\(formatter.string(from: p.date)),\(name),\(number(p.tempC)),\(number(p.humidity))")
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
