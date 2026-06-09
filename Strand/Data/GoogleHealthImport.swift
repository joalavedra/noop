import Foundation
import WhoopStore
import StrandImport

/// Persists a Google Health import (already fetched + normalized by
/// `GoogleHealthImporter` into an `AppleHealthImportResult`) into the on-device
/// store under its own source id ("google-health"), so it sits beside Whoop and
/// Apple Health for the per-source pages and cross-source consensus.
///
/// Mirrors `AppleHealthImport` — both share the Apple Health normalized model and
/// aggregator, so the recovery / strain / sleep analytics read Google data
/// unchanged.
enum GoogleHealthImport {

    static let deviceId = "google-health"

    /// Resolve a refresh token (from the Keychain, or a one-time browser sign-in),
    /// fetch `days` of history, and persist. Returns what was imported.
    /// `maxHR` / `sex` come from the user profile and drive the strain estimate.
    @discardableResult
    static func connect(clientId: String, clientSecret: String, days: Int,
                        maxHR: Double?, sex: String, into store: WhoopStore) async throws -> ImportSummary {
        let refreshToken: String
        if let saved = GoogleHealthKeychain.refreshToken {
            refreshToken = saved
        } else {
            let tokens = try await GoogleHealthAuth(clientId: clientId, clientSecret: clientSecret).authorize()
            refreshToken = tokens.refreshToken
        }
        GoogleHealthKeychain.store(clientId: clientId, clientSecret: clientSecret, refreshToken: refreshToken)

        let client = GoogleHealthClient(clientId: clientId, clientSecret: clientSecret, refreshToken: refreshToken)
        let result = try await GoogleHealthImporter(client: client).importRange(days: days)
        return try await persist(result, maxHR: maxHR, sex: sex, into: store)
    }

    /// Persist an already-fetched result, scoring recovery + strain.
    @discardableResult
    static func persist(_ result: AppleHealthImportResult, maxHR: Double?, sex: String,
                        into store: WhoopStore) async throws -> ImportSummary {
        let daily = AppleHealthAggregator.aggregate(result)

        let appleRows = daily.map { d in
            AppleDaily(day: d.day,
                       steps: d.steps.map { Int($0) },
                       activeKcal: d.activeKcal, basalKcal: d.basalKcal, vo2max: d.vo2max,
                       avgHr: d.avgHr.map { Int($0.rounded()) },
                       maxHr: d.maxHr.map { Int($0.rounded()) },
                       walkingHr: d.walkingHr.map { Int($0.rounded()) },
                       weightKg: d.weightKg)
        }
        try await store.upsertAppleDaily(appleRows, deviceId: deviceId)

        let dm = GoogleIntelligence.dailyMetrics(from: result, aggregates: daily, maxHR: maxHR, sex: sex)
        try await store.upsertDailyMetrics(dm, deviceId: deviceId)

        let points = AppleHealthAggregator.metricPoints(daily)
            .map { MetricPoint(day: $0.day, key: $0.key, value: $0.value) }
        try await store.upsertMetricSeries(points, deviceId: deviceId)

        let workouts = result.workouts.map { w in
            WorkoutRow(startTs: Int(w.start.timeIntervalSince1970),
                       endTs: Int(w.end.timeIntervalSince1970),
                       sport: w.activityType, source: "google_health",
                       durationS: w.durationS, energyKcal: w.energyKcal,
                       avgHr: nil, maxHr: nil, strain: nil,
                       distanceM: w.distanceM, zonesJSON: nil, notes: nil)
        }
        try await store.upsertWorkouts(workouts, deviceId: deviceId)

        return result.summary
    }
}
