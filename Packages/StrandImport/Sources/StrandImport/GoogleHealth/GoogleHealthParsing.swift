import Foundation

extension Calendar {
    /// A Gregorian calendar pinned to UTC, for building day-anchored timestamps.
    static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
}

extension GoogleHealthMapper {

    /// `daily-resting-heart-rate` → `dailyRestingHeartRate`.
    static func camelKey(_ dataType: String) -> String {
        let parts = dataType.split(separator: "-")
        guard let head = parts.first else { return dataType }
        return ([String(head)] + parts.dropFirst().map { $0.capitalized }).joined()
    }

    /// First numeric leaf in a JSON value (number, numeric string, or nested map).
    static func firstNumeric(_ value: Any?) -> Double? {
        switch value {
        case let d as Double: return d
        case let i as Int: return Double(i)
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s)
        case let dict as [String: Any]:
            for v in dict.values { if let n = firstNumeric(v) { return n } }
            return nil
        default:
            return nil
        }
    }

    /// Google `"-14400s"` UTC offset → minutes.
    static func offsetMinutes(_ value: Any?) -> Int {
        guard let s = value as? String, s.hasSuffix("s"), let sec = Int(s.dropLast()) else { return 0 }
        return sec / 60
    }

    /// Parse a Google timestamp (`2026-06-08T12:13:33Z`, with or without fractional
    /// seconds) to a UTC `Date`.
    static func parseDate(_ iso: String) -> Date? {
        let withFrac = ISO8601DateFormatter()
        withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFrac.date(from: iso) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: iso)
    }

    /// (timestamp, offsetMinutes) from a `sampleTime` payload.
    static func sampleTime(_ payload: [String: Any]) -> (Date, Int)? {
        guard let st = payload["sampleTime"] as? [String: Any],
              let phys = st["physicalTime"] as? String, let d = parseDate(phys) else { return nil }
        return (d, offsetMinutes(st["utcOffset"]))
    }

    /// (start, end, offsetMinutes) from an `interval` payload.
    static func interval(_ iv: [String: Any]) -> (Date, Date, Int)? {
        guard let s = iv["startTime"] as? String, let e = iv["endTime"] as? String,
              let sd = parseDate(s), let ed = parseDate(e) else { return nil }
        return (sd, ed, offsetMinutes(iv["startUtcOffset"]))
    }

    /// (start, end, offsetMinutes) from a sleep stage entry.
    static func stageInterval(_ stage: [String: Any]) -> (Date, Date, Int)? {
        guard let s = stage["startTime"] as? String, let e = stage["endTime"] as? String,
              let sd = parseDate(s), let ed = parseDate(e) else { return nil }
        return (sd, ed, offsetMinutes(stage["startUtcOffset"]))
    }

    /// Local midnight (UTC-built) for a daily metric's `date` field.
    static func civilDate(_ payload: [String: Any]) -> Date? {
        guard let date = payload["date"] as? [String: Any],
              let y = firstNumeric(date["year"]), let m = firstNumeric(date["month"]),
              let d = firstNumeric(date["day"]) else { return nil }
        return Calendar.utc.date(from: DateComponents(year: Int(y), month: Int(m), day: Int(d)))
    }

    /// Google duration string `"3600s"` (or number) → seconds.
    static func durationSeconds(_ value: Any?) -> Double? {
        if let s = value as? String, s.hasSuffix("s") { return Double(s.dropLast()) }
        return firstNumeric(value)
    }
}
