import Foundation
import WhoopStore
import WhoopProtocol
import StrandImport
import StrandAnalytics

/// Reproduces the WHOOP-style daily scores on imported Google Health data using
/// the same analytics the strap path uses: Recovery from HRV / resting HR / sleep
/// (`RecoveryScorer`) and day Strain from intraday heart rate (`StrainScorer`).
///
/// Google gives daily HRV/RHR/respiratory + sleep stages + intraday HR — not the
/// raw R-R / accelerometer streams `AnalyticsEngine.analyzeDay` expects — so this
/// computes from those aggregates directly and fills `recovery` + `strain` into
/// the daily rows the dashboard reads.
enum GoogleIntelligence {

    /// Build scored daily metrics from a Google import result + its aggregates.
    static func dailyMetrics(from result: AppleHealthImportResult,
                             aggregates daily: [AppleDailyAggregate],
                             maxHR: Double?, sex: String) -> [DailyMetric] {
        let hrByDay = heartRateByDay(result.samples)
        let hrvBase = Baselines.foldHistory(daily.map { $0.hrvSDNN }, cfg: Baselines.hrvCfg)
        let rhrBase = Baselines.foldHistory(daily.map { $0.restingHr }, cfg: Baselines.restingHRCfg)
        let respBase = Baselines.foldHistory(daily.map { $0.respRate }, cfg: Baselines.respCfg)

        return daily.map { d in
            let sleepPerf = efficiency(asleep: d.asleepMin, inBed: d.inBedMin)
            var recovery: Double?
            if let hrv = d.hrvSDNN, let rhr = d.restingHr {
                recovery = RecoveryScorer.recovery(
                    hrv: hrv, rhr: rhr, resp: d.respRate,
                    hrvBaseline: hrvBase, rhrBaseline: rhrBase, respBaseline: respBase,
                    sleepPerf: sleepPerf)
            }
            let dayHR = (hrByDay[d.day] ?? []).sorted { $0.ts < $1.ts }
            let strain = StrainScorer.strain(dayHR, maxHR: maxHR, restingHR: d.restingHr ?? 60, sex: sex)

            return DailyMetric(
                day: d.day, totalSleepMin: d.asleepMin, efficiency: sleepPerf.map { $0 * 100 },
                deepMin: d.deepMin, remMin: d.remMin, lightMin: d.coreMin, disturbances: nil,
                restingHr: d.restingHr.map { Int($0.rounded()) }, avgHrv: d.hrvSDNN,
                recovery: recovery, strain: strain, exerciseCount: nil,
                spo2Pct: d.spo2Pct, skinTempDevC: nil, respRateBpm: d.respRate)
        }
    }

    // MARK: - Helpers

    private static func efficiency(asleep: Double?, inBed: Double?) -> Double? {
        guard let a = asleep, let b = inBed, b > 0 else { return nil }
        return a / b
    }

    /// Group `HeartRate` samples into their local calendar day (`yyyy-MM-dd`),
    /// matching how the aggregator buckets days via each sample's UTC offset.
    private static func heartRateByDay(_ samples: [HealthSample]) -> [String: [HRSample]] {
        var out: [String: [HRSample]] = [:]
        for s in samples where s.type == "HeartRate" {
            guard let bpm = s.value else { continue }
            let key = localDayKey(s.start, tzOffsetMin: s.tzOffsetMin)
            out[key, default: []].append(HRSample(ts: Int(s.start.timeIntervalSince1970), bpm: Int(bpm)))
        }
        return out
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static func localDayKey(_ date: Date, tzOffsetMin: Int) -> String {
        dayFormatter.string(from: date.addingTimeInterval(Double(tzOffsetMin) * 60))
    }
}
