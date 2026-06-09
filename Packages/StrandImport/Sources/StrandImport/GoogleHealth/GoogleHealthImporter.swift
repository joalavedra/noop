import Foundation

/// Imports a date range from the Google Health API into the same
/// `AppleHealthImportResult` the Apple Health importer returns, so a Google /
/// Fitbit account drives NOOP's recovery, strain, and sleep analytics unchanged.
///
/// Credential-source agnostic: it takes a `GoogleHealthClient` (built from a
/// refresh token + OAuth client id/secret, e.g. from an in-app login).
public struct GoogleHealthImporter {

    /// Data types fetched by default. Each maps to HealthKit `Record`/`Workout`
    /// equivalents in `GoogleHealthMapper`.
    public static let dataTypes = [
        "heart-rate", "heart-rate-variability", "daily-resting-heart-rate",
        "oxygen-saturation", "daily-respiratory-rate", "steps", "weight",
        "sleep", "exercise",
    ]

    /// Daily-rollup types that reject member filters; fetched once, not per day.
    private static let dailyAggregates: Set<String> = [
        "daily-resting-heart-rate", "daily-respiratory-rate",
    ]

    private let client: GoogleHealthClient

    public init(client: GoogleHealthClient) {
        self.client = client
    }

    /// Fetch `days` ending on `endingOn` (default today) and return the normalized
    /// result. `types` overrides the default data-type set.
    public func importRange(days: Int, endingOn: Date = Date(),
                            types: [String]? = nil) async throws -> AppleHealthImportResult {
        let token = try await client.accessToken()
        let cal = Calendar.utc
        let end = cal.startOfDay(for: endingOn)
        let dayList = (0..<days).reversed().compactMap { cal.date(byAdding: .day, value: -$0, to: end) }

        var mapped = GoogleHealthMapper.Mapped()
        for type in types ?? Self.dataTypes {
            if Self.dailyAggregates.contains(type) {
                // No server-side filter — one unfiltered fetch returns the daily series.
                let points = (try? await client.dataPoints(type: type, day: end, token: token)) ?? []
                GoogleHealthMapper.map(type: type, points: points, into: &mapped)
            } else {
                for day in dayList {
                    let points = (try? await client.dataPoints(type: type, day: day, token: token)) ?? []
                    GoogleHealthMapper.map(type: type, points: points, into: &mapped)
                }
            }
        }
        return GoogleHealthMapper.result(mapped)
    }
}

// MARK: - Per-day server-side filters

extension GoogleHealthClient {

    private static let utcStamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    private static func civilDay(_ day: Date) -> String {
        let c = Calendar.utc.dateComponents([.year, .month, .day], from: day)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Candidate filter expressions for a data type and local day. Empty for daily
    /// aggregates, which reject member filters and are paged then date-matched by
    /// the mapper.
    static func filters(type: String, day: Date) -> [String] {
        let cal = Calendar.utc
        let next = cal.date(byAdding: .day, value: 1, to: day)!
        let startISO = utcStamp.string(from: day)
        let endISO = utcStamp.string(from: next)
        let d = civilDay(day), n = civilDay(next)
        let m = type.replacingOccurrences(of: "-", with: "_")

        switch type {
        case "heart-rate", "oxygen-saturation", "weight", "heart-rate-variability":
            return ["\(m).sample_time.physical_time >= \"\(startISO)\" AND \(m).sample_time.physical_time < \"\(endISO)\""]
        case "steps":
            return ["\(m).interval.start_time >= \"\(startISO)\" AND \(m).interval.start_time < \"\(endISO)\""]
        case "sleep", "exercise":
            return [
                "\(m).interval.civil_start_time >= \"\(d)T00:00:00\" AND \(m).interval.civil_start_time < \"\(n)T00:00:00\"",
                "\(m).interval.civil_end_time >= \"\(d)T00:00:00\" AND \(m).interval.civil_end_time < \"\(n)T00:00:00\"",
            ]
        default:
            return []
        }
    }
}
