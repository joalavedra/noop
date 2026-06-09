import Foundation
import Combine
import WhoopStore
import WhoopProtocol

/// Read model over the on-device WhoopStore. Opens its own handle (WAL + busy-timeout makes the
/// two-handle BLEManager+Repository pattern safe) and publishes the dashboard caches the screens bind to.
@MainActor
final class Repository: ObservableObject {
    let deviceId: String
    /// The source the dashboard reads. Resolves to whichever source actually has data —
    /// WHOOP first (a real strap/import always wins), else Google Health, else Apple Health —
    /// so an import-only user gets a fully populated dashboard without a strap.
    @Published private(set) var activeSource: String
    /// Source id for on-device computed scores (recovery/strain/sleep). Merged UNDER the
    /// imported rows at read time so an explicit import always wins.
    private var computedDeviceId: String { activeSource + "-noop" }
    private var store: WhoopStore?

    /// Daily metrics (recovery/strain/sleep/HRV/RHR…) over the recent window, oldest→newest.
    @Published var days: [DailyMetric] = []
    /// Cached sleep sessions over the recent window, oldest→newest.
    @Published var sleeps: [CachedSleepSession] = []
    @Published var loaded = false

    init(deviceId: String) { self.deviceId = deviceId; self.activeSource = deviceId }

    /// Today's row, by the device's ACTUAL local calendar date — NOT just the newest stored row, which
    /// after a historical import was months-old data shown as today's hero (issue #23). nil if no row
    /// for today yet (the dashboard then shows its empty/pending state).
    var today: DailyMetric? {
        let key = Repository.localDayKey(Date())
        return days.last(where: { $0.day == key })
    }
    /// The trailing 7 CALENDAR days ending today (for the week strip), oldest→newest — not the last 7
    /// stored rows, which on a stale import were old data. ISO yyyy-MM-dd compares chronologically.
    var week: [DailyMetric] {
        let cutoff = Repository.localDayKey(Calendar.current.date(byAdding: .day, value: -6, to: Date()) ?? Date())
        return days.filter { $0.day >= cutoff }
    }

    /// `yyyy-MM-dd` in the device's local zone, matching how `DailyMetric.day` is stored.
    private static let dayKeyFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()
    static func localDayKey(_ date: Date) -> String { dayKeyFormatter.string(from: date) }

    private func ensureStore() async -> WhoopStore? {
        if let store { return store }
        guard let path = try? StorePaths.defaultDatabasePath() else { return nil }
        let s = try? await WhoopStore(path: path)
        if let s { try? await s.upsertDevice(id: deviceId, mac: nil, name: "WHOOP") }
        store = s
        return s
    }

    /// Expose the shared store handle (used by the importer to persist mapped rows).
    func storeHandle() async -> WhoopStore? { await ensureStore() }

    /// Checkpoint the WAL into the main DB file if the store is already open, so a file-level
    /// backup captures everything. No-op (returns false) if no handle exists yet — the caller
    /// then copies the on-disk files as-is, which still includes the -wal sidecar.
    func checkpointForBackup() async -> Bool {
        guard let store else { return false }
        do { try await store.checkpointWAL(); return true } catch { return false }
    }

    /// Reload the dashboard caches over the last `nDays`, merging imported history with the
    /// on-device computed scores so a strap-only user still gets a populated dashboard.
    func refresh(days nDays: Int = 4000) async {
        guard let store = await ensureStore() else { return }
        await resolvePrimarySource(store)
        let now = Date()
        let fromDay = Self.dayString(now.addingTimeInterval(-Double(nDays) * 86_400))
        let toDay = Self.dayString(now.addingTimeInterval(86_400))
        let nowTs = Int(now.timeIntervalSince1970)
        let lo = nowTs - nDays * 86_400, hi = nowTs + 86_400

        let imported = (try? await store.dailyMetrics(deviceId: activeSource, from: fromDay, to: toDay)) ?? []
        let computed = (try? await store.dailyMetrics(deviceId: computedDeviceId, from: fromDay, to: toDay)) ?? []
        let impSleep = (try? await store.sleepSessions(deviceId: activeSource, from: lo, to: hi, limit: 4000)) ?? []
        let compSleep = (try? await store.sleepSessions(deviceId: computedDeviceId, from: lo, to: hi, limit: 4000)) ?? []

        self.days = Self.mergeDaily(imported: imported, computed: computed)
        self.sleeps = Self.mergeSleep(imported: impSleep, computed: compSleep)
        self.loaded = true
    }

    /// Pick the source the dashboard reads: WHOOP first (a real strap/import always wins),
    /// then Google Health, then Apple Health. Falls back to the WHOOP id when nothing imported.
    private func resolvePrimarySource(_ store: WhoopStore) async {
        let now = Date()
        let from = Self.dayString(now.addingTimeInterval(-4000 * 86_400))
        let to = Self.dayString(now.addingTimeInterval(86_400))
        for candidate in [deviceId, "google-health", "apple-health"] {
            let rows = (try? await store.dailyMetrics(deviceId: candidate, from: from, to: to)) ?? []
            let comp = (try? await store.dailyMetrics(deviceId: candidate + "-noop", from: from, to: to)) ?? []
            if !rows.isEmpty || !comp.isEmpty { activeSource = candidate; return }
        }
        activeSource = deviceId
    }

    /// Imported daily rows win per day; computed rows fill the days the import doesn't cover.
    private static func mergeDaily(imported: [DailyMetric], computed: [DailyMetric]) -> [DailyMetric] {
        var byDay: [String: DailyMetric] = [:]
        for d in computed { byDay[d.day] = d }   // computed first…
        for d in imported { byDay[d.day] = d }   // …import overwrites, so a real WHOOP import always wins
        return byDay.values.sorted { $0.day < $1.day }
    }

    /// Same precedence for sleep sessions, keyed by the day the night ends on.
    private static func mergeSleep(imported: [CachedSleepSession], computed: [CachedSleepSession]) -> [CachedSleepSession] {
        func endDay(_ s: CachedSleepSession) -> String {
            dayString(Date(timeIntervalSince1970: TimeInterval(s.endTs)))
        }
        var byDay: [String: CachedSleepSession] = [:]
        for s in computed { byDay[endDay(s)] = s }
        for s in imported { byDay[endDay(s)] = s }
        return byDay.values.sorted { $0.startTs < $1.startTs }
    }

    // MARK: - Detail passthroughs

    func dailyMetrics(fromDay: String, toDay: String) async -> [DailyMetric] {
        guard let store = await ensureStore() else { return [] }
        return (try? await store.dailyMetrics(deviceId: activeSource, from: fromDay, to: toDay)) ?? []
    }

    func hrSamples(from: Int, to: Int, limit: Int = 8000) async -> [HRSample] {
        guard let store = await ensureStore() else { return [] }
        return (try? await store.hrSamples(deviceId: activeSource, from: from, to: to, limit: limit)) ?? []
    }

    func sleepSessions(from: Int, to: Int, limit: Int = 100) async -> [CachedSleepSession] {
        guard let store = await ensureStore() else { return [] }
        return (try? await store.sleepSessions(deviceId: activeSource, from: from, to: to, limit: limit)) ?? []
    }

    // MARK: - Metric explorer reads (generic substrate)

    /// Daily series for any metric key from a given source ("my-whoop" / "apple-health").
    func series(key: String, source: String, days: Int = 4000) async -> [(day: String, value: Double)] {
        guard let store = await ensureStore() else { return [] }
        let now = Date()
        let from = Self.dayString(now.addingTimeInterval(-Double(days) * 86_400))
        let to = Self.dayString(now.addingTimeInterval(86_400))
        let pts = (try? await store.metricSeries(deviceId: source, key: key, from: from, to: to)) ?? []
        return pts.map { ($0.day, $0.value) }
    }

    func availableKeys(source: String) async -> [String] {
        guard let store = await ensureStore() else { return [] }
        return (try? await store.metricKeys(deviceId: source)) ?? []
    }

    /// Logged behaviours (Whoop journal) for correlation insights.
    func journalEntries(days: Int = 4000) async -> [JournalEntry] {
        guard let store = await ensureStore() else { return [] }
        let now = Date()
        return (try? await store.journalEntries(
            deviceId: activeSource,
            from: Self.dayString(now.addingTimeInterval(-Double(days) * 86_400)),
            to: Self.dayString(now.addingTimeInterval(86_400)))) ?? []
    }

    /// All workouts (Whoop + Apple Health), newest first.
    func workoutRows(days: Int = 4000) async -> [WorkoutRow] {
        guard let store = await ensureStore() else { return [] }
        let now = Int(Date().timeIntervalSince1970)
        let lo = now - days * 86_400, hi = now + 86_400
        var rows = (try? await store.workouts(deviceId: activeSource, from: lo, to: hi, limit: 5000)) ?? []
        rows += (try? await store.workouts(deviceId: "apple-health", from: lo, to: hi, limit: 5000)) ?? []
        return rows.sorted { $0.startTs > $1.startTs }
    }

    /// Apple Health / Google Health daily aggregates (steps/energy/vo2/hr/weight).
    func appleDailyRows(source: String = "apple-health", days: Int = 4000) async -> [AppleDaily] {
        guard let store = await ensureStore() else { return [] }
        let now = Date()
        return (try? await store.appleDaily(
            deviceId: source,
            from: Self.dayString(now.addingTimeInterval(-Double(days) * 86_400)),
            to: Self.dayString(now.addingTimeInterval(86_400)))) ?? []
    }

    /// Workouts for a single imported source ("apple-health" / "google-health"), newest first.
    func sourceWorkouts(deviceId: String, days: Int = 4000) async -> [WorkoutRow] {
        guard let store = await ensureStore() else { return [] }
        let now = Int(Date().timeIntervalSince1970)
        let rows = (try? await store.workouts(deviceId: deviceId, from: now - days * 86_400, to: now + 86_400, limit: 5000)) ?? []
        return rows.sorted { $0.startTs > $1.startTs }
    }

    /// Shared formatter — created once. Hot read path (called per series window / refresh);
    /// allocating a DateFormatter per call was a measurable waste. Read-only use is thread-safe.
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func dayString(_ d: Date) -> String { dayFormatter.string(from: d) }
}
