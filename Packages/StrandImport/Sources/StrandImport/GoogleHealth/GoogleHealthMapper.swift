import Foundation

/// Maps Google Health API `dataPoint` JSON (already parsed to dictionaries) into
/// the same normalized models the Apple Health importer produces, using the same
/// HealthKit `type` vocabulary so the downstream aggregator and analytics consume
/// Google data unchanged.
///
/// Value conventions match `AppleHealthImporter` output: `OxygenSaturation` is a
/// percentage (0–100), `HeartRateVariabilitySDNN` is milliseconds (Google's
/// RMSSD), `BodyMass` is kilograms.
public enum GoogleHealthMapper {

    /// Google sleep stage → the canonical `SleepStage`.
    static let sleepStage: [String: SleepStage] = [
        "DEEP": .asleepDeep, "LIGHT": .asleepCore, "REM": .asleepREM,
        "AWAKE": .awake, "ASLEEP": .asleepUnspecified, "RESTLESS": .awake,
    ]

    public struct Mapped {
        public var samples: [HealthSample] = []
        public var sleepIntervals: [SleepStageInterval] = []
        public var workouts: [HealthWorkout] = []
    }

    /// Accumulate one data type's points into `out`.
    public static func map(type: String, points: [[String: Any]], into out: inout Mapped) {
        for point in points {
            let payload = point[camelKey(type)] as? [String: Any] ?? [:]
            switch type {
            case "heart-rate":
                sample(payload, "HeartRate", "count/min", "beatsPerMinute", &out)
            case "heart-rate-variability":
                sample(payload, "HeartRateVariabilitySDNN", "ms",
                       "rootMeanSquareOfSuccessiveDifferencesMilliseconds", &out)
            case "oxygen-saturation":
                sample(payload, "OxygenSaturation", "%", "percentage", &out)
            case "weight":
                if let g = firstNumeric(payload["weightGrams"]), let (s, o) = sampleTime(payload) {
                    out.samples.append(make("BodyMass", g / 1000.0, "kg", s, s, o))
                }
            case "daily-resting-heart-rate":
                dailySample(point, type, payload, "RestingHeartRate", "count/min", "beatsPerMinute", &out)
            case "daily-respiratory-rate":
                dailySample(point, type, payload, "RespiratoryRate", "count/min", "breathsPerMinute", &out)
            case "steps":
                if let c = firstNumeric(payload["count"]),
                   let (s, e, o) = interval(payload["interval"] as? [String: Any] ?? [:]) {
                    out.samples.append(make("StepCount", c, "count", s, e, o))
                }
            case "sleep":
                mapSleep(payload, &out)
            case "exercise":
                if let w = workout(payload) { out.workouts.append(w) }
            default:
                break
            }
        }
    }

    /// Build an `AppleHealthImportResult` from accumulated, mapped data.
    public static func result(_ m: Mapped) -> AppleHealthImportResult {
        var counts: [String: Int] = [:]
        for s in m.samples { counts[s.type, default: 0] += 1 }
        counts["SleepAnalysis"] = (counts["SleepAnalysis"] ?? 0) + m.sleepIntervals.count
        counts["Workout"] = m.workouts.count
        let dates = m.samples.map(\.start) + m.sleepIntervals.map(\.start) + m.workouts.map(\.start)
        let summary = ImportSummary(sourceKind: .googleHealth,
                                    recordCount: m.samples.count + m.workouts.count,
                                    earliest: dates.min(), latest: dates.max(),
                                    countsByCategory: counts)
        return AppleHealthImportResult(samples: m.samples, workouts: m.workouts,
                                       sleepIntervals: m.sleepIntervals, summary: summary)
    }

    // MARK: - Per-shape helpers

    private static func sample(_ payload: [String: Any], _ type: String, _ unit: String,
                               _ key: String, _ out: inout Mapped) {
        guard let v = firstNumeric(payload[key]), let (ts, off) = sampleTime(payload) else { return }
        out.samples.append(make(type, v, unit, ts, ts, off))
    }

    private static func dailySample(_ point: [String: Any], _ type: String, _ payload: [String: Any],
                                    _ hkType: String, _ unit: String, _ key: String, _ out: inout Mapped) {
        guard let v = firstNumeric(payload[key]), let day = civilDate(payload) else { return }
        // Daily metrics have no time; anchor at 04:00 UTC so they land on their day.
        guard let ts = Calendar.utc.date(byAdding: .hour, value: 4, to: day) else { return }
        out.samples.append(make(hkType, v, unit, ts, ts, 0))
    }

    private static func mapSleep(_ payload: [String: Any], _ out: inout Mapped) {
        let iv = payload["interval"] as? [String: Any] ?? [:]
        if let (s, e, off) = interval(iv) {
            out.sleepIntervals.append(SleepStageInterval(stage: .inBed, start: s, end: e,
                                                         tzOffsetMin: off, sourceName: "Google Health"))
        }
        for stage in payload["stages"] as? [[String: Any]] ?? [] {
            let kind = (stage["type"] as? String ?? "").uppercased()
            guard let mapped = sleepStage[kind], let (s, e, off) = stageInterval(stage) else { continue }
            out.sleepIntervals.append(SleepStageInterval(stage: mapped, start: s, end: e,
                                                         tzOffsetMin: off, sourceName: "Google Health"))
        }
    }

    private static func workout(_ payload: [String: Any]) -> HealthWorkout? {
        let iv = payload["interval"] as? [String: Any] ?? [:]
        guard let (s, e, off) = interval(iv) else { return nil }
        let metrics = payload["metricsSummary"] as? [String: Any] ?? [:]
        let name = (payload["displayName"] as? String) ?? (payload["exerciseType"] as? String) ?? "Unknown"
        return HealthWorkout(
            activityType: name,
            durationS: durationSeconds(payload["activeDuration"]),
            distanceM: firstNumeric(metrics["distanceMeters"]),
            energyKcal: firstNumeric(metrics["caloriesKcal"]),
            start: s, end: e, tzOffsetMin: off, sourceName: "Google Health")
    }

    private static func make(_ type: String, _ value: Double, _ unit: String,
                             _ start: Date, _ end: Date, _ off: Int) -> HealthSample {
        HealthSample(type: type, value: value, valueString: String(value), unit: unit,
                     start: start, end: end, tzOffsetMin: off, sourceName: "Google Health")
    }
}
