import Foundation
import MimacIdentity
import SQLite3

public struct HistoryPolicy: Sendable {
    public let rawRetention: TimeInterval
    public let minuteRetention: TimeInterval
    public let hourRetention: TimeInterval
    public let maximumDatabaseBytes: UInt64

    public init(
        rawRetention: TimeInterval = 2 * 60 * 60,
        minuteRetention: TimeInterval = 7 * 24 * 60 * 60,
        hourRetention: TimeInterval = 90 * 24 * 60 * 60,
        maximumDatabaseBytes: UInt64 = 200 * 1_048_576
    ) {
        self.rawRetention = rawRetention
        self.minuteRetention = minuteRetention
        self.hourRetention = hourRetention
        self.maximumDatabaseBytes = maximumDatabaseBytes
    }
}

public enum HistoryStoreError: LocalizedError {
    case sqlite(message: String, code: Int32)
    case invalidRange

    public var errorDescription: String? {
        switch self {
        case .sqlite(let message, let code): return "SQLite error \(code): \(message)"
        case .invalidRange: return "History range must have an end after its start."
        }
    }
}

public final class HistoryStore: @unchecked Sendable {
    public static let defaultURL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Mimac/history.sqlite")

    private let url: URL
    private let policy: HistoryPolicy
    private var database: OpaquePointer?
    private var previousTimestamp: Date?
    private var previousOnBattery: Bool?
    private var previousEntityIDs = Set<String>()
    private var hasEntityBaseline = false
    private var lastMaintenanceBucket: Int64?

    public init(url: URL = HistoryStore.defaultURL, policy: HistoryPolicy = HistoryPolicy()) throws {
        self.url = url
        self.policy = policy
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "could not open database"
            if let handle { sqlite3_close(handle) }
            throw HistoryStoreError.sqlite(message: message, code: SQLITE_CANTOPEN)
        }
        database = handle
        do {
            try configure()
            try migrate()
            try enableIncrementalVacuum()
            try loadPreviousState()
            try performMaintenance(now: Date())
            lastMaintenanceBucket = Int64(Date().timeIntervalSince1970 / 60)
        } catch {
            sqlite3_close(handle)
            database = nil
            throw error
        }
    }

    deinit {
        if let database { sqlite3_close(database) }
    }

    public func persist(_ sample: CollectorTelemetry) throws {
        try transaction {
            try persistEntities(sample.entities, timestamp: sample.timestamp)
            try persistEntitySamples(sample)
            try persistSystemSample(sample)
            try persistEvents(sample)
        }

        previousTimestamp = sample.timestamp
        previousOnBattery = sample.onBattery
        if !sample.entities.isEmpty {
            previousEntityIDs = Set(sample.entities.map(\.entityID))
            hasEntityBaseline = true
        }

        let minuteBucket = Int64(sample.timestamp.timeIntervalSince1970 / 60)
        if lastMaintenanceBucket != minuteBucket {
            try performMaintenance(now: sample.timestamp)
            lastMaintenanceBucket = minuteBucket
        }
    }

    public func performMaintenance(now: Date = Date()) throws {
        let timestamp = now.timeIntervalSince1970
        let minuteCutoff = floor(timestamp / 60) * 60
        let hourCutoff = floor(timestamp / 3600) * 3600
        let dayCutoff = localDayStart(for: now).timeIntervalSince1970

        try transaction {
            // Each tier re-rolls only the buckets whose source rows this pass could
            // have written (plus everything after its last bucket, so restarts and
            // downtime catch up). Raw rows only ever arrive for the current time, so
            // a closed bucket's sources never change after they are rolled.
            //
            // This used to re-roll fixed lookbacks every minute: 4 hours of minutes
            // into hours and ~50 hours of minutes into days (a localtime strftime per
            // row), about 1.2 s of CPU per minute and the collector's largest cost.
            let minuteLower = try rollupLower(destination: "minutes", span: 60, dirtySince: minuteCutoff - 600)
            let systemMinuteLower = try rollupLower(destination: "system_minutes", span: 60, dirtySince: minuteCutoff - 600)
            try rollupEntities(source: "samples_raw", destination: "minutes", bucketSeconds: 60, lower: minuteLower, cutoff: minuteCutoff, sourceIsRaw: true)
            try rollupSystems(source: "system_samples", destination: "system_minutes", bucketSeconds: 60, lower: systemMinuteLower, cutoff: minuteCutoff, sourceIsRaw: true)
            let batteryDirtySince = try materializeBatteryAttribution(cutoff: minuteCutoff) ?? minuteCutoff
            let hourLower = try rollupLower(destination: "hours", span: 3600, dirtySince: minuteLower)
            let systemHourLower = try rollupLower(destination: "system_hours", span: 3600, dirtySince: systemMinuteLower)
            try rollupEntities(source: "minutes", destination: "hours", bucketSeconds: 3600, lower: hourLower, cutoff: hourCutoff, sourceIsRaw: false)
            try rollupSystems(source: "system_minutes", destination: "system_hours", bucketSeconds: 3600, lower: systemHourLower, cutoff: hourCutoff, sourceIsRaw: false)
            // Day tiers roll from minute-level sources so local-midnight boundaries stay
            // exact in timezones whose UTC offset is not a whole number of hours.
            let dayLower = try rollupLowerLocalDay(destination: "days", dirtySince: minuteLower)
            let systemDayLower = try rollupLowerLocalDay(destination: "system_days", dirtySince: systemMinuteLower)
            try rollupEntities(source: "minutes", destination: "days", bucketSeconds: 86400, lower: dayLower, cutoff: dayCutoff, sourceIsRaw: false)
            try rollupSystems(source: "system_minutes", destination: "system_days", bucketSeconds: 86400, lower: systemDayLower, cutoff: dayCutoff, sourceIsRaw: false)
            var batteryHourLower = try rollupLower(destination: "battery_windows_hours", span: 3600, dirtySince: batteryDirtySince)
            var batteryDayLower = try rollupLowerLocalDay(destination: "battery_windows_days", dirtySince: batteryDirtySince)
            if let stale = try staleBatteryPercentBucket() {
                batteryHourLower = min(batteryHourLower, stale)
                batteryDayLower = min(batteryDayLower, localDayStart(for: Date(timeIntervalSince1970: stale)).timeIntervalSince1970)
            }
            try rollupBatteryWindows(toHours: true, lower: batteryHourLower, cutoff: hourCutoff)
            try rollupBatteryAttribution(toHours: true, lower: batteryHourLower, cutoff: hourCutoff)
            try rollupBatteryWindows(toHours: false, lower: batteryDayLower, cutoff: dayCutoff)
            try rollupBatteryAttribution(toHours: false, lower: batteryDayLower, cutoff: dayCutoff)

            try execute("DELETE FROM samples_raw WHERE timestamp < ?", binds: [.double(timestamp - policy.rawRetention)])
            try execute("DELETE FROM system_samples WHERE timestamp < ?", binds: [.double(timestamp - policy.rawRetention)])
            try execute("DELETE FROM minutes WHERE bucket_start < ?", binds: [.double(timestamp - policy.minuteRetention)])
            try execute("DELETE FROM system_minutes WHERE bucket_start < ?", binds: [.double(timestamp - policy.minuteRetention)])
            try execute("DELETE FROM hours WHERE bucket_start < ?", binds: [.double(timestamp - policy.hourRetention)])
            try execute("DELETE FROM system_hours WHERE bucket_start < ?", binds: [.double(timestamp - policy.hourRetention)])
            try execute("DELETE FROM battery_windows WHERE window_start < ?", binds: [.double(timestamp - policy.minuteRetention)])
            try execute("DELETE FROM battery_windows_hours WHERE bucket_start < ?", binds: [.double(timestamp - policy.hourRetention)])
            try execute("DELETE FROM battery_attribution_hours WHERE bucket_start < ?", binds: [.double(timestamp - policy.hourRetention)])
            // Events had no retention at all and had grown to ~260k rows.
            try execute("DELETE FROM events WHERE started_at < ?", binds: [.double(timestamp - policy.hourRetention)])
        }

        try execute("PRAGMA wal_checkpoint(PASSIVE)")
        try enforceSizeCap(now: now)
    }

    public func entityTimeline(_ request: EntityTimelineRequest) throws -> EntityTimeline {
        let range = try validated(request.range)
        let resolution = resolved(range.resolution, duration: range.end.timeIntervalSince(range.start))
        let table = tableName(for: resolution, system: false)
        let timeColumn = resolution == .raw ? "timestamp" : "bucket_start"
        let sql: String
        if resolution == .raw {
            sql = """
            SELECT timestamp, interval_seconds, cpu_seconds, cpu_percent,
                   CAST(resident_bytes AS REAL), resident_bytes, disk_read_bytes,
                   disk_written_bytes, wakeups, energy_joules, power_watts
            FROM samples_raw
            WHERE entity_id = ? AND timestamp >= ? AND timestamp < ?
            ORDER BY timestamp
            """
        } else {
            sql = """
            SELECT \(timeColumn), duration_seconds, cpu_seconds, average_cpu_percent,
                   average_resident_bytes, peak_resident_bytes, disk_read_bytes,
                   disk_written_bytes, wakeups, energy_joules, average_power_watts
            FROM \(table)
            WHERE entity_id = ? AND \(timeColumn) >= ? AND \(timeColumn) < ?
            ORDER BY \(timeColumn)
            """
        }
        let statement = try Statement(database: requiredDatabase(), sql: sql)
        try statement.bind(.text(request.entityID), at: 1)
        try statement.bind(.double(range.start.timeIntervalSince1970), at: 2)
        try statement.bind(.double(range.end.timeIntervalSince1970), at: 3)
        var points: [EntityHistoryPoint] = []
        while try statement.stepRow() {
            points.append(EntityHistoryPoint(
                timestamp: Date(timeIntervalSince1970: statement.double(0)),
                durationSeconds: statement.double(1),
                cpuSeconds: statement.double(2),
                averageCPUPercent: statement.double(3),
                averageResidentBytes: statement.double(4),
                peakResidentBytes: statement.uint64(5),
                diskReadBytes: statement.uint64(6),
                diskWrittenBytes: statement.uint64(7),
                wakeups: statement.uint64(8),
                energyJoules: statement.double(9),
                averagePowerWatts: statement.double(10)
            ))
        }
        let name = try scalarText("SELECT display_name FROM entities WHERE entity_id = ?", binds: [.text(request.entityID)])
        return EntityTimeline(entityID: request.entityID, displayName: name, resolution: resolution, points: points)
    }

    public func topEntities(_ request: TopEntitiesRequest) throws -> [RankedEntityHistory] {
        let range = try validated(request.range)
        let resolution = resolved(range.resolution, duration: range.end.timeIntervalSince(range.start))
        let table = tableName(for: resolution, system: false)
        let timeColumn = resolution == .raw ? "timestamp" : "bucket_start"
        let metricExpression: String
        switch (request.metric, resolution) {
        case (.cpuSeconds, _): metricExpression = "SUM(h.cpu_seconds)"
        case (.energyJoules, _): metricExpression = "SUM(h.energy_joules)"
        case (.residentBytes, .raw): metricExpression = "SUM(CAST(h.resident_bytes AS REAL) * h.interval_seconds) / MAX(SUM(h.interval_seconds), 0.001)"
        case (.residentBytes, _): metricExpression = "SUM(h.average_resident_bytes * h.duration_seconds) / MAX(SUM(h.duration_seconds), 0.001)"
        case (.diskReadBytes, _): metricExpression = "SUM(h.disk_read_bytes)"
        case (.diskWrittenBytes, _): metricExpression = "SUM(h.disk_written_bytes)"
        case (.wakeups, _): metricExpression = "SUM(h.wakeups)"
        }
        let sql = """
        SELECT h.entity_id, e.display_name, e.kind, \(metricExpression) AS metric_value
        FROM \(table) h
        JOIN entities e ON e.entity_id = h.entity_id
        WHERE h.\(timeColumn) >= ? AND h.\(timeColumn) < ?
        GROUP BY h.entity_id
        ORDER BY metric_value DESC
        LIMIT ?
        """
        let statement = try Statement(database: requiredDatabase(), sql: sql)
        try statement.bind(.double(range.start.timeIntervalSince1970), at: 1)
        try statement.bind(.double(range.end.timeIntervalSince1970), at: 2)
        try statement.bind(.int64(Int64(min(100, max(1, request.limit)))), at: 3)
        var result: [RankedEntityHistory] = []
        while try statement.stepRow() {
            result.append(RankedEntityHistory(
                entityID: statement.text(0) ?? "unknown",
                displayName: statement.text(1) ?? "Unknown",
                kind: EntityKind(rawValue: statement.text(2) ?? "") ?? .unknown,
                value: statement.double(3),
                metric: request.metric
            ))
        }
        return result
    }

    public func systemTimeline(_ rangeValue: HistoryRange) throws -> SystemTimeline {
        let range = try validated(rangeValue)
        let resolution = resolved(range.resolution, duration: range.end.timeIntervalSince(range.start))
        let table = tableName(for: resolution, system: true)
        let timeColumn = resolution == .raw ? "timestamp" : "bucket_start"
        let sql: String
        if resolution == .raw {
            sql = """
            SELECT timestamp, interval_seconds, battery_watts, battery_percent, battery_percent,
                   system_cpu_percent, system_gpu_percent, on_battery,
                   memory_pressure_rank, thermal_rank
            FROM system_samples WHERE timestamp >= ? AND timestamp < ? ORDER BY timestamp
            """
        } else {
            sql = """
            SELECT \(timeColumn), duration_seconds, average_battery_watts,
                   minimum_battery_percent, maximum_battery_percent,
                   average_cpu_percent, average_gpu_percent, on_battery_fraction,
                   worst_memory_pressure, worst_thermal_state
            FROM \(table) WHERE \(timeColumn) >= ? AND \(timeColumn) < ? ORDER BY \(timeColumn)
            """
        }
        let statement = try Statement(database: requiredDatabase(), sql: sql)
        try statement.bind(.double(range.start.timeIntervalSince1970), at: 1)
        try statement.bind(.double(range.end.timeIntervalSince1970), at: 2)
        var points: [SystemHistoryPoint] = []
        while try statement.stepRow() {
            points.append(SystemHistoryPoint(
                timestamp: Date(timeIntervalSince1970: statement.double(0)),
                durationSeconds: statement.double(1),
                averageBatteryWatts: statement.optionalDouble(2),
                minimumBatteryPercent: statement.optionalInt(3),
                maximumBatteryPercent: statement.optionalInt(4),
                averageCPUPercent: statement.double(5),
                averageGPUPercent: statement.optionalDouble(6),
                onBatteryFraction: statement.double(7),
                worstMemoryPressure: pressure(from: statement.int(8)),
                worstThermalState: thermal(from: statement.int(9))
            ))
        }
        return SystemTimeline(resolution: resolution, points: points)
    }

    public func health() throws -> HistoryStorageHealth {
        let dayAgo = Date().timeIntervalSince1970 - 24 * 3600
        let minutesLast24h = Int(try scalarInt64("SELECT COUNT(*) FROM system_minutes WHERE bucket_start >= \(dayAgo)") ?? 0)
        return HistoryStorageHealth(
            databasePath: url.path,
            databaseBytes: databaseBytes(),
            rawEntitySamples: try count("samples_raw"),
            rawSystemSamples: try count("system_samples"),
            minuteRollups: try count("minutes"),
            hourRollups: try count("hours"),
            dayRollups: try count("days"),
            batteryWindows: try count("battery_windows"),
            batteryHourRollups: try count("battery_windows_hours"),
            batteryDayRollups: try count("battery_windows_days"),
            minuteFillRatePercent24h: Double(minutesLast24h) / 1440 * 100,
            eventCount: try count("events"),
            lastPersistedAt: try scalarDouble("SELECT MAX(timestamp) FROM system_samples").map(Date.init(timeIntervalSince1970:))
        )
    }

    public func entityUsage(_ request: EntityUsageRequest) throws -> [EntityUsageSummary] {
        let range = try validated(request.range)
        let windowSeconds = range.end.timeIntervalSince(range.start)
        // Raw samples cover short windows exactly (including the newest seconds);
        // the minute tier is far cheaper once the window is long enough that a
        // trailing unrolled minute no longer matters.
        let useRaw = windowSeconds <= 30 * 60
        let table = useRaw ? "samples_raw" : "minutes"
        let time = useRaw ? "timestamp" : "bucket_start"
        let duration = useRaw ? "interval_seconds" : "duration_seconds"
        let resident = useRaw ? "CAST(h.resident_bytes AS REAL)" : "h.average_resident_bytes"
        // CPU and power share one denominator: the whole window. Averaging CPU over
        // only the seconds an entity was alive let a 15-second burst at 100% outrank
        // ten minutes of steady 20% (DESIGN.md: a burst must not outrank sustained
        // load). Memory stays an average over the time the entity existed, since a
        // footprint diluted by time it was not running means nothing.
        let statement = try Statement(database: requiredDatabase(), sql: """
        SELECT h.entity_id, e.display_name, e.kind, e.project,
               SUM(h.cpu_seconds) * 100.0 / \(max(1, windowSeconds)),
               SUM(\(resident) * h.\(duration)) / MAX(SUM(h.\(duration)), 0.001),
               SUM(h.disk_read_bytes + h.disk_written_bytes) / MAX(SUM(h.\(duration)), 0.001),
               SUM(h.energy_joules) / \(max(1, windowSeconds)),
               SUM(h.energy_joules),
               SUM(h.\(duration))
        FROM \(table) h
        JOIN entities e ON e.entity_id = h.entity_id
        WHERE h.\(time) >= ? AND h.\(time) < ?
        GROUP BY h.entity_id
        ORDER BY SUM(h.energy_joules) DESC, SUM(h.cpu_seconds) DESC
        LIMIT ?
        """)
        try statement.bind(.double(range.start.timeIntervalSince1970), at: 1)
        try statement.bind(.double(range.end.timeIntervalSince1970), at: 2)
        try statement.bind(.int64(Int64(min(500, max(1, request.limit)))), at: 3)
        var result: [EntityUsageSummary] = []
        while try statement.stepRow() {
            result.append(EntityUsageSummary(
                entityID: statement.text(0) ?? "unknown",
                displayName: statement.text(1) ?? "Unknown",
                kind: EntityKind(rawValue: statement.text(2) ?? "") ?? .unknown,
                project: statement.text(3),
                averageCPUPercent: statement.double(4),
                averageResidentBytes: statement.double(5),
                diskBytesPerSecond: statement.double(6),
                averagePowerWatts: statement.double(7),
                energyJoules: statement.double(8),
                activeSeconds: statement.double(9),
                windowSeconds: windowSeconds
            ))
        }
        result += try hardwareUsage(start: range.start, end: range.end, windowSeconds: windowSeconds, useRaw: useRaw)
        return result.sorted { $0.energyJoules > $1.energyJoules }
    }

    /// Memory & chip and Display & rest of Mac over the window, shaped like
    /// entities so the averaged table adds up to the draw the same way the
    /// live one does. Power shares the whole window as its denominator, like
    /// every entity; windows before schema 6 simply have no rows.
    private func hardwareUsage(start: Date, end: Date, windowSeconds: Double, useRaw: Bool) throws -> [EntityUsageSummary] {
        let table = useRaw ? "system_samples" : "system_minutes"
        let time = useRaw ? "timestamp" : "bucket_start"
        let covered = useRaw
            ? "SUM(CASE WHEN rest_of_mac_joules IS NOT NULL THEN interval_seconds ELSE 0 END)"
            : "SUM(COALESCE(breakdown_seconds, 0))"
        let statement = try Statement(database: requiredDatabase(), sql: """
        SELECT SUM(chip_joules), SUM(rest_of_mac_joules), \(covered)
        FROM \(table) WHERE \(time) >= ? AND \(time) < ?
        """)
        try statement.bind(.double(start.timeIntervalSince1970), at: 1)
        try statement.bind(.double(end.timeIntervalSince1970), at: 2)
        guard try statement.stepRow() else { return [] }
        let chip = statement.optionalDouble(0)
        let rest = statement.optionalDouble(1)
        let seconds = statement.double(2)
        guard let rest, seconds > 0 else { return [] }
        let window = max(1, windowSeconds)
        func row(_ id: String, _ name: String, _ joules: Double) -> EntityUsageSummary {
            EntityUsageSummary(
                entityID: id, displayName: name, kind: .system, project: nil,
                averageCPUPercent: 0, averageResidentBytes: 0, diskBytesPerSecond: 0,
                averagePowerWatts: max(0, joules) / window, energyJoules: max(0, joules),
                activeSeconds: seconds, windowSeconds: windowSeconds
            )
        }
        var rows: [EntityUsageSummary] = []
        if let chip { rows.append(row(SyntheticEntity.chipID, "Memory & chip", chip)) }
        rows.append(row(SyntheticEntity.restOfMacID, chip == nil ? "Rest of system" : "Display & rest of Mac", rest))
        return rows
    }

    public func batteryHistory(_ request: BatteryHistoryRequest) throws -> BatteryHistoryReport {
        let range = try validated(request.range)
        let resolution = batteryResolution(range.resolution, duration: range.end.timeIntervalSince(range.start))
        let start = range.start.timeIntervalSince1970
        let end = range.end.timeIntervalSince1970
        var timeline: [BatteryDrainPoint] = []
        var totalJoules = 0.0
        var totalPercent = 0.0
        var attributedDuration = 0.0
        var excludedDuration = 0.0
        var rawMeasuredJoules = 0.0
        let rowsSQL: String
        let rowsBinds: [BindValue]

        if resolution == .minute {
            let windows = try Statement(database: requiredDatabase(), sql: """
            SELECT window_start, duration_seconds, total_joules, capacity_wh, excluded_reason, raw_measured_joules
            FROM battery_windows WHERE window_start >= ? AND window_start < ? ORDER BY window_start
            """)
            try windows.bind(.double(start), at: 1)
            try windows.bind(.double(end), at: 2)
            while try windows.stepRow() {
                let duration = windows.double(1)
                let reason = windows.text(4)
                let joules = windows.double(2)
                let capacity = windows.optionalDouble(3)
                if reason == nil {
                    totalJoules += joules
                    rawMeasuredJoules += windows.double(5)
                    attributedDuration += duration
                    if let capacity, capacity > 0 { totalPercent += joules / (capacity * 3600) * 100 }
                } else {
                    excludedDuration += duration
                }
                timeline.append(BatteryDrainPoint(
                    timestamp: Date(timeIntervalSince1970: windows.double(0)),
                    durationSeconds: duration,
                    drainWatts: reason == nil && duration > 0 ? joules / duration : nil,
                    drainJoules: reason == nil ? joules : nil,
                    onBattery: reason == nil,
                    excludedReason: reason
                ))
            }
            rowsSQL = """
            SELECT a.item_id, MAX(a.display_name), a.category, MAX(a.kind),
                   SUM(a.measured_joules), SUM(a.heuristic_joules),
                   SUM((a.measured_joules + a.heuristic_joules) / NULLIF(w.capacity_wh * 3600, 0) * 100),
                   SUM(a.foreground_joules), SUM(a.background_joules), SUM(a.active_seconds),
                   SUM((a.measured_joules + a.heuristic_joules)) / MAX(SUM(a.active_seconds), 0.001),
                   MAX(a.peak_watts), MAX(a.confidence_rank), MAX(a.cause)
            FROM battery_attribution a
            JOIN battery_windows w ON w.window_start = a.window_start
            WHERE a.window_start >= ? AND a.window_start < ? AND w.excluded_reason IS NULL
            GROUP BY a.item_id, a.category
            ORDER BY SUM(a.measured_joules + a.heuristic_joules) DESC
            """
            rowsBinds = [.double(start), .double(end)]
        } else {
            let isHour = resolution == .hour
            let windowTable = isHour ? "battery_windows_hours" : "battery_windows_days"
            let attributionTable = isHour ? "battery_attribution_hours" : "battery_attribution_days"
            // Rolled buckets end at the boundary after the newest rolled bucket; windows
            // past that boundary (today / the current hour) are aggregated live so recent
            // drain is never invisible until the next rollup closes its bucket.
            let liveBoundary = try batteryLiveBoundary(windowTable: windowTable, isHour: isHour)
            let bucket = batteryBucketExpression(toHours: isHour, column: "window_start")
            let windows = try Statement(database: requiredDatabase(), sql: """
            SELECT bucket, SUM(attributed), SUM(excluded), SUM(joules), SUM(raw_measured), SUM(percent), MAX(reason)
            FROM (
              SELECT bucket_start AS bucket, attributed_seconds AS attributed, excluded_seconds AS excluded,
                     total_joules AS joules, raw_measured_joules AS raw_measured, total_percent AS percent,
                     excluded_reason AS reason
              FROM \(windowTable) WHERE bucket_start >= ?1 AND bucket_start < ?2
              UNION ALL
              SELECT \(bucket),
                CASE WHEN excluded_reason IS NULL THEN duration_seconds ELSE 0 END,
                CASE WHEN excluded_reason IS NOT NULL THEN duration_seconds ELSE 0 END,
                CASE WHEN excluded_reason IS NULL THEN total_joules ELSE 0 END,
                CASE WHEN excluded_reason IS NULL THEN raw_measured_joules ELSE 0 END,
                CASE WHEN excluded_reason IS NULL AND capacity_wh > 0 THEN total_joules / (capacity_wh * 3600) * 100 ELSE 0 END,
                excluded_reason
              FROM battery_windows WHERE window_start >= ?3 AND window_start >= ?1 AND window_start < ?2
            )
            GROUP BY bucket ORDER BY bucket
            """)
            try windows.bind(.double(start), at: 1)
            try windows.bind(.double(end), at: 2)
            try windows.bind(.double(liveBoundary), at: 3)
            while try windows.stepRow() {
                let attributed = windows.double(1)
                let excluded = windows.double(2)
                let joules = windows.double(3)
                attributedDuration += attributed
                excludedDuration += excluded
                totalJoules += joules
                rawMeasuredJoules += windows.double(4)
                totalPercent += windows.double(5)
                timeline.append(BatteryDrainPoint(
                    timestamp: Date(timeIntervalSince1970: windows.double(0)),
                    durationSeconds: attributed + excluded,
                    drainWatts: attributed > 0 ? joules / attributed : nil,
                    drainJoules: attributed > 0 ? joules : nil,
                    onBattery: attributed > 0,
                    excludedReason: attributed > 0 ? nil : (windows.text(6) ?? "no attributed windows")
                ))
            }
            rowsSQL = """
            SELECT item_id, MAX(name), category, MAX(kind), SUM(measured), SUM(heuristic),
                   COALESCE(SUM(percent), 0), SUM(foreground), SUM(background), SUM(active),
                   SUM(measured + heuristic) / MAX(SUM(active), 0.001),
                   MAX(peak), MAX(confidence), MAX(cause)
            FROM (
              SELECT item_id, display_name AS name, category, kind, measured_joules AS measured,
                     heuristic_joules AS heuristic, battery_percent AS percent,
                     foreground_joules AS foreground, background_joules AS background,
                     active_seconds AS active, peak_watts AS peak, confidence_rank AS confidence, cause
              FROM \(attributionTable) WHERE bucket_start >= ?1 AND bucket_start < ?2
              UNION ALL
              SELECT a.item_id, a.display_name, a.category, a.kind, a.measured_joules, a.heuristic_joules,
                     (a.measured_joules + a.heuristic_joules) / NULLIF(w.capacity_wh * 3600, 0) * 100,
                     a.foreground_joules, a.background_joules, a.active_seconds, a.peak_watts,
                     a.confidence_rank, a.cause
              FROM battery_attribution a
              JOIN battery_windows w ON w.window_start = a.window_start
              WHERE w.excluded_reason IS NULL AND a.window_start >= ?3 AND a.window_start >= ?1 AND a.window_start < ?2
            )
            GROUP BY item_id, category
            ORDER BY SUM(measured + heuristic) DESC
            """
            rowsBinds = [.double(start), .double(end), .double(liveBoundary)]
        }

        let statement = try Statement(database: requiredDatabase(), sql: rowsSQL)
        for (offset, bind) in rowsBinds.enumerated() { try statement.bind(bind, at: Int32(offset + 1)) }
        var rows: [BatteryAttributionRow] = []
        while try statement.stepRow() {
            let measured = statement.double(4)
            let heuristic = statement.double(5)
            let energy = measured + heuristic
            rows.append(BatteryAttributionRow(
                id: statement.text(0) ?? "unknown",
                displayName: statement.text(1) ?? "Unknown",
                category: AttributionCategory(rawValue: statement.text(2) ?? "") ?? .unattributed,
                kind: statement.text(3).flatMap(EntityKind.init(rawValue:)),
                measuredJoules: measured,
                heuristicJoules: heuristic,
                batteryPercent: statement.double(6),
                shareOfDrain: totalJoules > 0 ? energy / totalJoules : 0,
                foregroundJoules: statement.double(7),
                backgroundJoules: statement.double(8),
                activeDurationSeconds: statement.double(9),
                averageWatts: statement.double(10),
                peakWatts: statement.double(11),
                confidence: confidence(from: statement.int(12)),
                dominantCause: statement.text(13) ?? "Attribution model"
            ))
        }
        let reconciliation = totalJoules > 0 ? abs(totalJoules - rawMeasuredJoules) / totalJoules * 100 : 0
        return BatteryHistoryReport(range: range, resolution: resolution, attributedDurationSeconds: attributedDuration, excludedDurationSeconds: excludedDuration, totalDrainJoules: totalJoules, totalBatteryPercent: totalPercent, reconciliationErrorPercent: reconciliation, rows: rows, timeline: timeline)
    }

    private func batteryLiveBoundary(windowTable: String, isHour: Bool) throws -> Double {
        guard let maxBucket = try scalarDouble("SELECT MAX(bucket_start) FROM \(windowTable)") else { return 0 }
        if isHour { return maxBucket + 3600 }
        let maxDayStart = localDayStart(for: Date(timeIntervalSince1970: maxBucket))
        return Calendar.current.date(byAdding: .day, value: 1, to: maxDayStart)?.timeIntervalSince1970 ?? maxBucket + 86400
    }

    private func batteryResolution(_ requested: HistoryResolution, duration: TimeInterval) -> HistoryResolution {
        switch requested {
        case .raw, .minute: return .minute
        case .hour: return .hour
        case .day: return .day
        case .automatic:
            if duration <= 48 * 3600 { return .minute }
            if duration <= 8 * 24 * 3600 { return .hour }
            return .day
        }
    }

    private func configure() throws {
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA synchronous=NORMAL")
        try execute("PRAGMA foreign_keys=ON")
        try execute("PRAGMA busy_timeout=2500")
        try execute("PRAGMA auto_vacuum=INCREMENTAL")
    }

    /// `PRAGMA auto_vacuum=INCREMENTAL` in `configure()` is a no-op on a database
    /// that already has tables; it only takes effect after a full VACUUM. Databases
    /// created before that pragma existed stayed in NONE mode, so every
    /// `incremental_vacuum` was a no-op, deleted rows never returned pages to the
    /// filesystem, and the file stayed above the size cap permanently. One-time
    /// conversion; a failure (for example, too little free disk for the rewrite)
    /// is not fatal because the cap now measures live pages rather than file size.
    private func enableIncrementalVacuum() throws {
        guard (try scalarInt64("PRAGMA auto_vacuum")) != 2 else { return }
        try execute("PRAGMA auto_vacuum=INCREMENTAL")
        try? execute("VACUUM")
    }

    private func migrate() throws {
        try execute("""
        CREATE TABLE IF NOT EXISTS entities (
            entity_id TEXT PRIMARY KEY,
            display_name TEXT NOT NULL,
            kind TEXT NOT NULL,
            project TEXT,
            first_seen REAL NOT NULL,
            last_seen REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS samples_raw (
            timestamp REAL NOT NULL,
            sequence INTEGER NOT NULL,
            entity_id TEXT NOT NULL REFERENCES entities(entity_id),
            interval_seconds REAL NOT NULL,
            cpu_seconds REAL NOT NULL,
            cpu_percent REAL NOT NULL,
            resident_bytes INTEGER NOT NULL,
            disk_read_bytes INTEGER NOT NULL,
            disk_written_bytes INTEGER NOT NULL,
            wakeups INTEGER NOT NULL,
            energy_joules REAL NOT NULL,
            power_watts REAL NOT NULL,
            PRIMARY KEY (timestamp, entity_id)
        ) WITHOUT ROWID;
        CREATE INDEX IF NOT EXISTS samples_raw_entity_time ON samples_raw(entity_id, timestamp);
        CREATE TABLE IF NOT EXISTS system_samples (
            timestamp REAL PRIMARY KEY,
            sequence INTEGER NOT NULL,
            interval_seconds REAL NOT NULL,
            on_battery INTEGER NOT NULL,
            battery_watts REAL,
            battery_percent INTEGER,
            system_cpu_percent REAL NOT NULL,
            system_gpu_percent REAL,
            memory_pressure_rank INTEGER NOT NULL,
            disk_read_bytes_per_second REAL NOT NULL,
            disk_written_bytes_per_second REAL NOT NULL,
            thermal_rank INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            event_type TEXT NOT NULL,
            started_at REAL NOT NULL,
            ended_at REAL,
            entity_id TEXT,
            metadata TEXT
        );
        CREATE INDEX IF NOT EXISTS events_time ON events(started_at);
        """)
        for table in ["minutes", "hours", "days"] {
            try execute(entityRollupSchema(table))
        }
        for table in ["system_minutes", "system_hours", "system_days"] {
            try execute(systemRollupSchema(table))
        }
        let version = Int(try scalarInt64("PRAGMA user_version") ?? 0)
        if version < 2 {
            try execute("ALTER TABLE samples_raw ADD COLUMN p_core_cpu_seconds REAL NOT NULL DEFAULT 0")
            try execute("ALTER TABLE samples_raw ADD COLUMN foreground INTEGER NOT NULL DEFAULT 0")
            try execute("ALTER TABLE system_samples ADD COLUMN capacity_wh REAL")
            try execute("ALTER TABLE system_samples ADD COLUMN battery_voltage REAL")
            try execute("ALTER TABLE system_samples ADD COLUMN display_brightness REAL")
            try execute("ALTER TABLE system_samples ADD COLUMN screen_on INTEGER NOT NULL DEFAULT 1")
            try execute("""
            CREATE TABLE IF NOT EXISTS battery_windows (
                window_start REAL PRIMARY KEY,
                duration_seconds REAL NOT NULL,
                total_joules REAL NOT NULL,
                capacity_wh REAL,
                excluded_reason TEXT
            );
            CREATE TABLE IF NOT EXISTS battery_attribution (
                window_start REAL NOT NULL REFERENCES battery_windows(window_start) ON DELETE CASCADE,
                item_id TEXT NOT NULL,
                display_name TEXT NOT NULL,
                category TEXT NOT NULL,
                kind TEXT,
                measured_joules REAL NOT NULL,
                heuristic_joules REAL NOT NULL,
                foreground_joules REAL NOT NULL,
                background_joules REAL NOT NULL,
                active_seconds REAL NOT NULL,
                peak_watts REAL NOT NULL,
                confidence_rank INTEGER NOT NULL,
                cause TEXT NOT NULL,
                PRIMARY KEY(window_start, item_id)
            ) WITHOUT ROWID;
            CREATE INDEX IF NOT EXISTS battery_attribution_time ON battery_attribution(window_start);
            """)
            try execute("PRAGMA user_version=2")
        }
        if version < 3 {
            try execute("ALTER TABLE battery_windows ADD COLUMN raw_measured_joules REAL NOT NULL DEFAULT 0")
            try execute("PRAGMA user_version=3")
        }
        if version < 4 {
            for table in ["battery_windows_hours", "battery_windows_days"] {
                try execute(batteryWindowRollupSchema(table))
            }
            for table in ["battery_attribution_hours", "battery_attribution_days"] {
                try execute(batteryAttributionRollupSchema(table))
            }
            try execute("PRAGMA user_version=4")
        }
        if version < 5 {
            // Temperature and real memory accounting. As with the columns added
            // in v2, the CREATE TABLE strings above stay frozen at their
            // original shape and every later column arrives by ALTER, so a
            // fresh database and an upgraded one end up identical.
            for column in ["cpu_temp_c REAL", "gpu_temp_c REAL", "battery_temp_c REAL", "enclosure_temp_c REAL",
                           "memory_used_bytes INTEGER", "memory_total_bytes INTEGER", "swap_used_bytes INTEGER"] {
                try execute("ALTER TABLE system_samples ADD COLUMN \(column)")
            }
            for table in ["system_minutes", "system_hours", "system_days"] {
                for column in ["average_cpu_temp_c REAL", "peak_cpu_temp_c REAL", "peak_gpu_temp_c REAL",
                               "average_memory_used_bytes REAL", "peak_memory_used_bytes REAL"] {
                    try execute("ALTER TABLE \(table) ADD COLUMN \(column)")
                }
            }
            try execute("PRAGMA user_version=5")
        }
        if version < 6 {
            // The hardware rows of the live table (Memory & chip, Display &
            // rest of Mac) as energy, so averaged windows can show them and
            // their rows still add up to the machine's draw. Null where the
            // collector had no system power reading; chip is also null when
            // only the whole-Mac figure was readable.
            try execute("ALTER TABLE system_samples ADD COLUMN chip_joules REAL")
            try execute("ALTER TABLE system_samples ADD COLUMN rest_of_mac_joules REAL")
            for table in ["system_minutes", "system_hours", "system_days"] {
                for column in ["chip_joules REAL", "rest_of_mac_joules REAL", "breakdown_seconds REAL"] {
                    try execute("ALTER TABLE \(table) ADD COLUMN \(column)")
                }
            }
            try execute("PRAGMA user_version=6")
        }
    }

    private func batteryWindowRollupSchema(_ table: String) -> String {
        """
        CREATE TABLE IF NOT EXISTS \(table) (
            bucket_start REAL PRIMARY KEY,
            attributed_seconds REAL NOT NULL,
            excluded_seconds REAL NOT NULL,
            total_joules REAL NOT NULL,
            raw_measured_joules REAL NOT NULL,
            total_percent REAL NOT NULL,
            excluded_reason TEXT
        );
        """
    }

    private func batteryAttributionRollupSchema(_ table: String) -> String {
        """
        CREATE TABLE IF NOT EXISTS \(table) (
            bucket_start REAL NOT NULL,
            item_id TEXT NOT NULL,
            display_name TEXT NOT NULL,
            category TEXT NOT NULL,
            kind TEXT,
            measured_joules REAL NOT NULL,
            heuristic_joules REAL NOT NULL,
            battery_percent REAL NOT NULL,
            foreground_joules REAL NOT NULL,
            background_joules REAL NOT NULL,
            active_seconds REAL NOT NULL,
            peak_watts REAL NOT NULL,
            confidence_rank INTEGER NOT NULL,
            cause TEXT NOT NULL,
            PRIMARY KEY (bucket_start, item_id)
        ) WITHOUT ROWID;
        CREATE INDEX IF NOT EXISTS \(table)_time ON \(table)(bucket_start);
        """
    }

    private func entityRollupSchema(_ table: String) -> String {
        """
        CREATE TABLE IF NOT EXISTS \(table) (
            bucket_start REAL NOT NULL,
            entity_id TEXT NOT NULL REFERENCES entities(entity_id),
            duration_seconds REAL NOT NULL,
            sample_count INTEGER NOT NULL,
            cpu_seconds REAL NOT NULL,
            average_cpu_percent REAL NOT NULL,
            average_resident_bytes REAL NOT NULL,
            peak_resident_bytes INTEGER NOT NULL,
            disk_read_bytes INTEGER NOT NULL,
            disk_written_bytes INTEGER NOT NULL,
            wakeups INTEGER NOT NULL,
            energy_joules REAL NOT NULL,
            average_power_watts REAL NOT NULL,
            PRIMARY KEY (bucket_start, entity_id)
        ) WITHOUT ROWID;
        CREATE INDEX IF NOT EXISTS \(table)_entity_time ON \(table)(entity_id, bucket_start);
        """
    }

    private func systemRollupSchema(_ table: String) -> String {
        """
        CREATE TABLE IF NOT EXISTS \(table) (
            bucket_start REAL PRIMARY KEY,
            duration_seconds REAL NOT NULL,
            sample_count INTEGER NOT NULL,
            average_battery_watts REAL,
            minimum_battery_percent INTEGER,
            maximum_battery_percent INTEGER,
            average_cpu_percent REAL NOT NULL,
            average_gpu_percent REAL,
            on_battery_fraction REAL NOT NULL,
            worst_memory_pressure INTEGER NOT NULL,
            worst_thermal_state INTEGER NOT NULL
        );
        """
    }

    private func persistEntities(_ entities: [EntityTelemetry], timestamp: Date) throws {
        let statement = try Statement(database: requiredDatabase(), sql: """
        INSERT INTO entities(entity_id, display_name, kind, project, first_seen, last_seen)
        VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT(entity_id) DO UPDATE SET
          display_name=excluded.display_name,
          kind=excluded.kind,
          project=excluded.project,
          last_seen=excluded.last_seen
        """)
        for entity in entities {
            try statement.bind(.text(entity.entityID), at: 1)
            try statement.bind(.text(entity.displayName), at: 2)
            try statement.bind(.text(entity.kind.rawValue), at: 3)
            try statement.bind(entity.project.map(BindValue.text) ?? .null, at: 4)
            try statement.bind(.double(timestamp.timeIntervalSince1970), at: 5)
            try statement.bind(.double(timestamp.timeIntervalSince1970), at: 6)
            try statement.stepDone()
            statement.reset()
        }
    }

    private func persistEntitySamples(_ sample: CollectorTelemetry) throws {
        let statement = try Statement(database: requiredDatabase(), sql: """
        INSERT OR REPLACE INTO samples_raw(
          timestamp, sequence, entity_id, interval_seconds, cpu_seconds, cpu_percent,
          resident_bytes, disk_read_bytes, disk_written_bytes, wakeups, energy_joules, power_watts,
          p_core_cpu_seconds, foreground
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """)
        for entity in sample.entities {
            let values: [BindValue] = [
                .double(sample.timestamp.timeIntervalSince1970), .int64(Int64(bitPattern: sample.sequence)),
                .text(entity.entityID), .double(sample.sampleIntervalSeconds), .double(entity.cpuSeconds),
                .double(entity.cpuPercent), .int64(clampedInt64(entity.residentBytes)),
                .int64(clampedInt64(entity.diskReadBytes)), .int64(clampedInt64(entity.diskWrittenBytes)),
                .int64(clampedInt64(entity.wakeups)), .double(entity.energyJoules), .double(entity.powerWatts),
                .double(entity.pCoreCPUSeconds), .int64(entity.foreground ? 1 : 0),
            ]
            for (offset, value) in values.enumerated() { try statement.bind(value, at: Int32(offset + 1)) }
            try statement.stepDone()
            statement.reset()
        }
    }

    private func persistSystemSample(_ sample: CollectorTelemetry) throws {
        try execute("""
        INSERT OR REPLACE INTO system_samples(
          timestamp, sequence, interval_seconds, on_battery, battery_watts, battery_percent,
          system_cpu_percent, system_gpu_percent, memory_pressure_rank,
          disk_read_bytes_per_second, disk_written_bytes_per_second, thermal_rank,
          capacity_wh, battery_voltage, display_brightness, screen_on,
          cpu_temp_c, gpu_temp_c, battery_temp_c, enclosure_temp_c,
          memory_used_bytes, memory_total_bytes, swap_used_bytes,
          chip_joules, rest_of_mac_joules
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, binds: [
            .double(sample.timestamp.timeIntervalSince1970), .int64(Int64(bitPattern: sample.sequence)),
            .double(sample.sampleIntervalSeconds), .int64(sample.onBattery ? 1 : 0),
            sample.batteryWatts.map(BindValue.double) ?? .null,
            sample.batteryPercent.map { .int64(Int64($0)) } ?? .null,
            .double(sample.systemCPUPercent), sample.systemGPUPercent.map(BindValue.double) ?? .null,
            .int64(Int64(pressureRank(sample.memoryPressure))), .double(sample.diskReadBytesPerSecond),
            .double(sample.diskWrittenBytesPerSecond), .int64(Int64(thermalRank(sample.thermalState))),
            sample.batteryFullChargeCapacityWh.map(BindValue.double) ?? .null,
            sample.batteryVoltage.map(BindValue.double) ?? .null,
            sample.displayBrightness.map(BindValue.double) ?? .null,
            .int64(sample.screenOn ? 1 : 0),
            sample.temperature?.cpuCelsius.map(BindValue.double) ?? .null,
            sample.temperature?.gpuCelsius.map(BindValue.double) ?? .null,
            sample.temperature?.batteryCelsius.map(BindValue.double) ?? .null,
            sample.temperature?.enclosureCelsius.map(BindValue.double) ?? .null,
            sample.memory.map { .int64(clampedInt64($0.usedBytes)) } ?? .null,
            sample.memory.map { .int64(clampedInt64($0.totalBytes)) } ?? .null,
            sample.memory.map { .int64(clampedInt64($0.swapUsedBytes)) } ?? .null,
            sample.powerBreakdown?.chipWatts.map { .double($0 * sample.sampleIntervalSeconds) } ?? .null,
            sample.powerBreakdown.map { .double($0.restOfMacWatts * sample.sampleIntervalSeconds) } ?? .null,
        ])
        if let capacity = sample.batteryFullChargeCapacityWh, capacity > 0 {
            try execute("UPDATE system_samples SET capacity_wh = ? WHERE capacity_wh IS NULL", binds: [.double(capacity)])
            try execute("UPDATE battery_windows SET capacity_wh = ? WHERE capacity_wh IS NULL", binds: [.double(capacity)])
        }
    }

    private func persistEvents(_ sample: CollectorTelemetry) throws {
        if let previousTimestamp {
            let gap = sample.timestamp.timeIntervalSince(previousTimestamp)
            let threshold = max(60, sample.sampleIntervalSeconds * 3)
            if gap > threshold {
                try insertEvent(type: "sample_gap", start: previousTimestamp, end: sample.timestamp, metadata: "{\"durationSeconds\":\(gap)}")
            }
        }
        if let previousOnBattery, previousOnBattery != sample.onBattery {
            try insertEvent(
                type: sample.onBattery ? "battery_started" : "external_power_started",
                start: sample.timestamp,
                end: nil,
                metadata: nil
            )
        }
        if hasEntityBaseline, !sample.entities.isEmpty {
            let currentIDs = Set(sample.entities.map(\.entityID))
            for entityID in currentIDs.subtracting(previousEntityIDs) {
                try insertEvent(type: "entity_started", start: sample.timestamp, end: nil, entityID: entityID, metadata: nil)
            }
            for entityID in previousEntityIDs.subtracting(currentIDs) {
                try insertEvent(type: "entity_stopped", start: sample.timestamp, end: nil, entityID: entityID, metadata: nil)
            }
        }
    }

    private func insertEvent(type: String, start: Date, end: Date?, entityID: String? = nil, metadata: String?) throws {
        try execute(
            "INSERT INTO events(event_type, started_at, ended_at, entity_id, metadata) VALUES (?, ?, ?, ?, ?)",
            binds: [.text(type), .double(start.timeIntervalSince1970), end.map { .double($0.timeIntervalSince1970) } ?? .null, entityID.map(BindValue.text) ?? .null, metadata.map(BindValue.text) ?? .null]
        )
    }

    /// Oldest closed hour bucket that recorded drain but 0% battery even though its
    /// source windows now carry a capacity — i.e. it was rolled while capacity was
    /// unknown (macOS 27 renamed the capacity keys) and later backfilled. Closed
    /// buckets are otherwise never re-rolled, so these would read 0% forever.
    /// Self-clearing: once re-rolled the bucket has a percentage and stops matching.
    private func staleBatteryPercentBucket() throws -> Double? {
        try scalarDouble("""
        SELECT MIN(h.bucket_start) FROM battery_windows_hours h
        WHERE h.total_percent = 0 AND h.total_joules > 0 AND EXISTS (
          SELECT 1 FROM battery_windows w
          WHERE w.window_start >= h.bucket_start AND w.window_start < h.bucket_start + 3600
            AND w.excluded_reason IS NULL AND w.capacity_wh > 0
        )
        """)
    }

    /// First bucket to re-roll: the one holding the earliest source row this pass
    /// may have written, or the bucket after the tier's last, whichever is older.
    private func rollupLower(destination: String, span: Double, dirtySince: Double) throws -> Double {
        let aligned = floor(dirtySince / span) * span
        guard let maxBucket = try scalarDouble("SELECT MAX(bucket_start) FROM \(destination)") else { return 0 }
        return min(aligned, maxBucket + span)
    }

    private func rollupLowerLocalDay(destination: String, dirtySince: Double) throws -> Double {
        let aligned = localDayStart(for: Date(timeIntervalSince1970: dirtySince)).timeIntervalSince1970
        guard let maxBucket = try scalarDouble("SELECT MAX(bucket_start) FROM \(destination)") else { return 0 }
        let maxDayStart = localDayStart(for: Date(timeIntervalSince1970: maxBucket))
        let nextDay = Calendar.current.date(byAdding: .day, value: 1, to: maxDayStart)?.timeIntervalSince1970 ?? maxBucket + 86400
        return min(aligned, nextDay)
    }

    private func rollupEntities(source: String, destination: String, bucketSeconds: Int, lower: Double, cutoff: Double, sourceIsRaw: Bool) throws {
        let time = sourceIsRaw ? "timestamp" : "bucket_start"
        let bucket = destination == "days"
            ? "CAST(strftime('%s', datetime(\(time), 'unixepoch', 'localtime', 'start of day', 'utc')) AS REAL)"
            : "CAST(\(time) / \(bucketSeconds) AS INTEGER) * \(bucketSeconds)"
        let duration = sourceIsRaw ? "interval_seconds" : "duration_seconds"
        let cpuPercent = sourceIsRaw ? "cpu_percent" : "average_cpu_percent"
        let resident = sourceIsRaw ? "CAST(resident_bytes AS REAL)" : "average_resident_bytes"
        let peak = sourceIsRaw ? "resident_bytes" : "peak_resident_bytes"
        let power = sourceIsRaw ? "power_watts" : "average_power_watts"
        try execute("""
        INSERT OR REPLACE INTO \(destination)(
          bucket_start, entity_id, duration_seconds, sample_count, cpu_seconds,
          average_cpu_percent, average_resident_bytes, peak_resident_bytes,
          disk_read_bytes, disk_written_bytes, wakeups, energy_joules, average_power_watts
        )
        SELECT \(bucket), entity_id,
          SUM(\(duration)), SUM(\(sourceIsRaw ? "1" : "sample_count")), SUM(cpu_seconds),
          SUM(\(cpuPercent) * \(duration)) / MAX(SUM(\(duration)), 0.001),
          SUM(\(resident) * \(duration)) / MAX(SUM(\(duration)), 0.001), MAX(\(peak)),
          SUM(disk_read_bytes), SUM(disk_written_bytes), SUM(wakeups), SUM(energy_joules),
          SUM(\(power) * \(duration)) / MAX(SUM(\(duration)), 0.001)
        FROM \(source) WHERE \(time) >= ? AND \(time) < ?
        GROUP BY \(bucket), entity_id
        """, binds: [.double(lower), .double(cutoff)])
    }

    private func rollupSystems(source: String, destination: String, bucketSeconds: Int, lower: Double, cutoff: Double, sourceIsRaw: Bool) throws {
        let time = sourceIsRaw ? "timestamp" : "bucket_start"
        let bucket = destination == "system_days"
            ? "CAST(strftime('%s', datetime(\(time), 'unixepoch', 'localtime', 'start of day', 'utc')) AS REAL)"
            : "CAST(\(time) / \(bucketSeconds) AS INTEGER) * \(bucketSeconds)"
        let duration = sourceIsRaw ? "interval_seconds" : "duration_seconds"
        let batteryWatts = sourceIsRaw ? "battery_watts" : "average_battery_watts"
        let minBattery = sourceIsRaw ? "battery_percent" : "minimum_battery_percent"
        let maxBattery = sourceIsRaw ? "battery_percent" : "maximum_battery_percent"
        let cpu = sourceIsRaw ? "system_cpu_percent" : "average_cpu_percent"
        let gpu = sourceIsRaw ? "system_gpu_percent" : "average_gpu_percent"
        let onBattery = sourceIsRaw ? "on_battery" : "on_battery_fraction"
        let pressure = sourceIsRaw ? "memory_pressure_rank" : "worst_memory_pressure"
        let thermal = sourceIsRaw ? "thermal_rank" : "worst_thermal_state"
        let cpuTemp = sourceIsRaw ? "cpu_temp_c" : "average_cpu_temp_c"
        let peakCPUTemp = sourceIsRaw ? "cpu_temp_c" : "peak_cpu_temp_c"
        let peakGPUTemp = sourceIsRaw ? "gpu_temp_c" : "peak_gpu_temp_c"
        let memoryUsed = sourceIsRaw ? "CAST(memory_used_bytes AS REAL)" : "average_memory_used_bytes"
        let peakMemoryUsed = sourceIsRaw ? "CAST(memory_used_bytes AS REAL)" : "peak_memory_used_bytes"
        let breakdownSeconds = sourceIsRaw
            ? "CASE WHEN rest_of_mac_joules IS NOT NULL THEN interval_seconds ELSE 0 END"
            : "COALESCE(breakdown_seconds, 0)"
        try execute("""
        INSERT OR REPLACE INTO \(destination)(
          bucket_start, duration_seconds, sample_count, average_battery_watts,
          minimum_battery_percent, maximum_battery_percent, average_cpu_percent,
          average_gpu_percent, on_battery_fraction, worst_memory_pressure, worst_thermal_state,
          average_cpu_temp_c, peak_cpu_temp_c, peak_gpu_temp_c,
          average_memory_used_bytes, peak_memory_used_bytes,
          chip_joules, rest_of_mac_joules, breakdown_seconds
        )
        SELECT \(bucket), SUM(\(duration)),
          SUM(\(sourceIsRaw ? "1" : "sample_count")),
          SUM(CASE WHEN \(batteryWatts) IS NOT NULL THEN \(batteryWatts) * \(duration) ELSE 0 END) /
            NULLIF(SUM(CASE WHEN \(batteryWatts) IS NOT NULL THEN \(duration) ELSE 0 END), 0),
          MIN(\(minBattery)), MAX(\(maxBattery)),
          SUM(\(cpu) * \(duration)) / MAX(SUM(\(duration)), 0.001),
          SUM(CASE WHEN \(gpu) IS NOT NULL THEN \(gpu) * \(duration) ELSE 0 END) /
            NULLIF(SUM(CASE WHEN \(gpu) IS NOT NULL THEN \(duration) ELSE 0 END), 0),
          SUM(\(onBattery) * \(duration)) / MAX(SUM(\(duration)), 0.001), MAX(\(pressure)), MAX(\(thermal)),
          SUM(CASE WHEN \(cpuTemp) IS NOT NULL THEN \(cpuTemp) * \(duration) ELSE 0 END) /
            NULLIF(SUM(CASE WHEN \(cpuTemp) IS NOT NULL THEN \(duration) ELSE 0 END), 0),
          MAX(\(peakCPUTemp)), MAX(\(peakGPUTemp)),
          SUM(CASE WHEN \(memoryUsed) IS NOT NULL THEN \(memoryUsed) * \(duration) ELSE 0 END) /
            NULLIF(SUM(CASE WHEN \(memoryUsed) IS NOT NULL THEN \(duration) ELSE 0 END), 0),
          MAX(\(peakMemoryUsed)),
          SUM(chip_joules), SUM(rest_of_mac_joules), SUM(\(breakdownSeconds))
        FROM \(source) WHERE \(time) >= ? AND \(time) < ?
        GROUP BY \(bucket)
        """, binds: [.double(lower), .double(cutoff)])
    }

    private func batteryBucketExpression(toHours: Bool, column: String) -> String {
        toHours
            ? "CAST(\(column) / 3600 AS INTEGER) * 3600"
            : "CAST(strftime('%s', datetime(\(column), 'unixepoch', 'localtime', 'start of day', 'utc')) AS REAL)"
    }

    private func rollupBatteryWindows(toHours: Bool, lower: Double, cutoff: Double) throws {
        let destination = toHours ? "battery_windows_hours" : "battery_windows_days"
        let bucket = batteryBucketExpression(toHours: toHours, column: "window_start")
        try execute("""
        INSERT OR REPLACE INTO \(destination)(
          bucket_start, attributed_seconds, excluded_seconds, total_joules,
          raw_measured_joules, total_percent, excluded_reason
        )
        SELECT \(bucket),
          SUM(CASE WHEN excluded_reason IS NULL THEN duration_seconds ELSE 0 END),
          SUM(CASE WHEN excluded_reason IS NOT NULL THEN duration_seconds ELSE 0 END),
          SUM(CASE WHEN excluded_reason IS NULL THEN total_joules ELSE 0 END),
          SUM(CASE WHEN excluded_reason IS NULL THEN raw_measured_joules ELSE 0 END),
          COALESCE(SUM(CASE WHEN excluded_reason IS NULL AND capacity_wh > 0
            THEN total_joules / (capacity_wh * 3600) * 100 END), 0),
          MAX(excluded_reason)
        FROM battery_windows WHERE window_start >= ? AND window_start < ?
        GROUP BY \(bucket)
        """, binds: [.double(lower), .double(cutoff)])
    }

    private func rollupBatteryAttribution(toHours: Bool, lower: Double, cutoff: Double) throws {
        let destination = toHours ? "battery_attribution_hours" : "battery_attribution_days"
        let bucket = batteryBucketExpression(toHours: toHours, column: "a.window_start")
        try execute("""
        INSERT OR REPLACE INTO \(destination)(
          bucket_start, item_id, display_name, category, kind, measured_joules,
          heuristic_joules, battery_percent, foreground_joules, background_joules,
          active_seconds, peak_watts, confidence_rank, cause
        )
        SELECT \(bucket), a.item_id, MAX(a.display_name),
          MAX(a.category), MAX(a.kind), SUM(a.measured_joules), SUM(a.heuristic_joules),
          COALESCE(SUM((a.measured_joules + a.heuristic_joules) / NULLIF(w.capacity_wh * 3600, 0) * 100), 0),
          SUM(a.foreground_joules), SUM(a.background_joules), SUM(a.active_seconds),
          MAX(a.peak_watts), MAX(a.confidence_rank), MAX(a.cause)
        FROM battery_attribution a
        JOIN battery_windows w ON w.window_start = a.window_start
        WHERE w.excluded_reason IS NULL AND a.window_start >= ? AND a.window_start < ?
        GROUP BY \(bucket), a.item_id
        """, binds: [.double(lower), .double(cutoff)])
    }

    private struct AttributionSystemSample {
        let timestamp: Double
        let watts: Double?
        let onBattery: Bool
        let capacityWh: Double?
        let brightness: Double?
        let screenOn: Bool
    }

    private struct AttributionEntitySample {
        let id: String
        let name: String
        let kind: EntityKind
        let energy: Double
        let cpu: Double
        let pCPU: Double
        let disk: Double
        let wakeups: Double
        let foregroundFraction: Double
        let activeSeconds: Double
        let peakWatts: Double
    }

    /// Returns the start of the earliest window written, or nil when none were, so
    /// the battery rollups know which buckets this pass touched.
    @discardableResult
    private func materializeBatteryAttribution(cutoff: Double) throws -> Double? {
        // Resume after the last materialized window: samples only arrive for the current
        // time, so closed windows never change, and minutes sampled just before a long
        // sleep still get attributed at the next maintenance no matter how late it runs.
        let lower: Double
        if let lastWindow = try scalarDouble("SELECT MAX(window_start) FROM battery_windows") {
            lower = lastWindow + 60
        } else if let earliest = try scalarDouble("SELECT MIN(timestamp) FROM system_samples") {
            lower = floor(earliest / 60) * 60
        } else {
            return nil
        }
        guard lower < cutoff else { return nil }
        // Only minutes that contain samples become windows; unsampled minutes (sleep,
        // daemon downtime) stay absent rather than flooding the store with exclusions.
        let minutes = try Statement(database: requiredDatabase(), sql: """
        SELECT DISTINCT CAST(timestamp / 60 AS INTEGER) * 60 FROM system_samples
        WHERE timestamp >= ? AND timestamp < ? ORDER BY 1
        """)
        try minutes.bind(.double(lower), at: 1)
        try minutes.bind(.double(cutoff), at: 2)
        var starts: [Double] = []
        while try minutes.stepRow() { starts.append(minutes.double(0)) }
        for start in starts {
            try materializeBatteryWindow(start: start)
        }
        return starts.first
    }

    private func materializeBatteryWindow(start: Double) throws {
        let end = start + 60
        let query = try Statement(database: requiredDatabase(), sql: """
        SELECT timestamp, battery_watts, on_battery, capacity_wh, display_brightness, screen_on
        FROM system_samples WHERE timestamp >= ? AND timestamp < ? ORDER BY timestamp
        """)
        try query.bind(.double(start), at: 1)
        try query.bind(.double(end), at: 2)
        var systems: [AttributionSystemSample] = []
        while try query.stepRow() {
            systems.append(AttributionSystemSample(
                timestamp: query.double(0), watts: query.optionalDouble(1), onBattery: query.int(2) != 0,
                capacityWh: query.optionalDouble(3), brightness: query.optionalDouble(4), screenOn: query.int(5) != 0
            ))
        }

        try execute("DELETE FROM battery_attribution WHERE window_start = ?", binds: [.double(start)])
        try execute("DELETE FROM battery_windows WHERE window_start = ?", binds: [.double(start)])
        let capacity = average(systems.compactMap(\.capacityWh))
        guard systems.count >= 2 else {
            try insertBatteryWindow(start: start, duration: 60, total: 0, capacity: capacity, rawMeasured: 0, excluded: "insufficient samples")
            return
        }
        guard systems.allSatisfy(\.onBattery) else {
            try insertBatteryWindow(start: start, duration: 60, total: 0, capacity: capacity, rawMeasured: 0, excluded: "charging or wall power")
            return
        }
        guard systems.allSatisfy({ $0.watts != nil }) else {
            try insertBatteryWindow(start: start, duration: 60, total: 0, capacity: capacity, rawMeasured: 0, excluded: "gas gauge unavailable")
            return
        }
        var total = 0.0
        var duration = 0.0
        var largestGap = 0.0
        for pair in zip(systems, systems.dropFirst()) {
            let delta = pair.1.timestamp - pair.0.timestamp
            largestGap = max(largestGap, delta)
            guard delta > 0 else { continue }
            total += ((pair.0.watts ?? 0) + (pair.1.watts ?? 0)) / 2 * delta
            duration += delta
        }
        guard duration > 0, largestGap <= 60 else {
            try insertBatteryWindow(start: start, duration: 60, total: 0, capacity: capacity, rawMeasured: 0, excluded: "sleep or sample gap")
            return
        }

        let entities = try attributionEntities(start: start, end: end)
        let rawMeasured = entities.reduce(0) { $0 + max(0, $1.energy) }
        try insertBatteryWindow(start: start, duration: duration, total: total, capacity: capacity, rawMeasured: rawMeasured, excluded: nil)

        let measuredScale = rawMeasured > total && rawMeasured > 0 ? total / rawMeasured : 1
        let measuredBudget = min(total, rawMeasured)
        var residual = max(0, total - measuredBudget)
        let screenFraction = Double(systems.filter(\.screenOn).count) / Double(systems.count)
        let brightnessValues = systems.compactMap(\.brightness)
        let brightness = average(brightnessValues) ?? 0.5
        let displayModel = duration * screenFraction * (0.8 + 3.2 * brightness)
        let display = min(residual, displayModel)
        residual -= display
        let system = min(residual, duration * 1.2)
        residual -= system
        let radios = min(residual, duration * 0.15)
        residual -= radios

        // The unreadable-processes row has CPU but, by definition, no counters; a
        // CPU-share heuristic would hand it most of the residual on no evidence.
        let counterless = entities.filter { $0.energy <= 0 && $0.id != SyntheticEntity.unreadableProcessesID }
        let scores = counterless.map { entity -> Double in
            let eCPU = max(0, entity.cpu - entity.pCPU)
            return max(0, entity.pCPU * 4 + eCPU + entity.disk / 50_000_000 + entity.wakeups / 500)
        }
        let scoreTotal = scores.reduce(0, +)
        let heuristicPool = scoreTotal > 0 ? residual * 0.7 : 0
        residual -= heuristicPool

        for entity in entities where entity.energy > 0 {
            let energy = entity.energy * measuredScale
            let foreground = energy * entity.foregroundFraction
            // From schema 6 the unreadable-processes row carries energy too: the
            // CPU rail minus every readable counter, plus its GPU share.
            let cause = entity.id == SyntheticEntity.unreadableProcessesID
                ? "CPU power rail minus readable processes"
                : "Measured process energy counter"
            try insertAttribution(start: start, id: entity.id, name: entity.name, category: .entity, kind: entity.kind, measured: energy, heuristic: 0, foreground: foreground, background: energy - foreground, active: entity.activeSeconds, peak: entity.peakWatts, confidence: rawMeasured <= total * 1.15 ? .high : .low, cause: cause)
        }
        for (entity, score) in zip(counterless, scores) where score > 0 {
            let energy = heuristicPool * score / scoreTotal
            let foreground = energy * entity.foregroundFraction
            try insertAttribution(start: start, id: entity.id, name: entity.name, category: .entity, kind: entity.kind, measured: 0, heuristic: energy, foreground: foreground, background: energy - foreground, active: entity.activeSeconds, peak: max(entity.peakWatts, energy / max(duration, 0.001)), confidence: .medium, cause: "QoS-weighted CPU, I/O, and wakeup activity")
        }
        try insertBucket(start: start, id: "bucket:display", name: "Display", category: .display, joules: display, duration: duration, confidence: brightnessValues.isEmpty ? .low : .medium, cause: brightnessValues.isEmpty ? "Screen-on fallback model" : "Brightness × screen-on model")
        try insertBucket(start: start, id: "bucket:system", name: "System", category: .system, joules: system, duration: duration, confidence: .low, cause: "Residual system baseline")
        try insertBucket(start: start, id: "bucket:radios", name: "Radios", category: .radios, joules: radios, duration: duration, confidence: .low, cause: "Residual radio baseline")
        try insertBucket(start: start, id: "bucket:unattributed", name: "Unattributed", category: .unattributed, joules: residual, duration: duration, confidence: .low, cause: "Energy not supported by measured or heuristic evidence")
    }

    private func attributionEntities(start: Double, end: Double) throws -> [AttributionEntitySample] {
        let statement = try Statement(database: requiredDatabase(), sql: """
        SELECT s.entity_id, MAX(e.display_name), MAX(e.kind), SUM(s.energy_joules),
               SUM(s.cpu_seconds), SUM(s.p_core_cpu_seconds),
               SUM(s.disk_read_bytes + s.disk_written_bytes), SUM(s.wakeups),
               SUM(CASE WHEN s.foreground = 1 THEN s.interval_seconds ELSE 0 END) / MAX(SUM(s.interval_seconds), 0.001),
               SUM(CASE WHEN s.cpu_percent >= 1 OR s.energy_joules > 0 OR s.wakeups > 0 THEN s.interval_seconds ELSE 0 END),
               MAX(s.power_watts)
        FROM samples_raw s JOIN entities e ON e.entity_id = s.entity_id
        WHERE s.timestamp >= ? AND s.timestamp < ? GROUP BY s.entity_id
        """)
        try statement.bind(.double(start), at: 1)
        try statement.bind(.double(end), at: 2)
        var result: [AttributionEntitySample] = []
        while try statement.stepRow() {
            result.append(AttributionEntitySample(
                id: statement.text(0) ?? "unknown", name: statement.text(1) ?? "Unknown",
                kind: EntityKind(rawValue: statement.text(2) ?? "") ?? .unknown,
                energy: statement.double(3), cpu: statement.double(4), pCPU: statement.double(5),
                disk: statement.double(6), wakeups: statement.double(7), foregroundFraction: statement.double(8),
                activeSeconds: statement.double(9), peakWatts: statement.double(10)
            ))
        }
        return result
    }

    private func insertBatteryWindow(start: Double, duration: Double, total: Double, capacity: Double?, rawMeasured: Double, excluded: String?) throws {
        try execute("INSERT INTO battery_windows(window_start, duration_seconds, total_joules, capacity_wh, excluded_reason, raw_measured_joules) VALUES (?, ?, ?, ?, ?, ?)", binds: [.double(start), .double(duration), .double(total), capacity.map(BindValue.double) ?? .null, excluded.map(BindValue.text) ?? .null, .double(rawMeasured)])
    }

    private func insertBucket(start: Double, id: String, name: String, category: AttributionCategory, joules: Double, duration: Double, confidence: AttributionConfidence, cause: String) throws {
        try insertAttribution(start: start, id: id, name: name, category: category, kind: nil, measured: 0, heuristic: joules, foreground: 0, background: joules, active: duration, peak: duration > 0 ? joules / duration : 0, confidence: confidence, cause: cause)
    }

    private func insertAttribution(start: Double, id: String, name: String, category: AttributionCategory, kind: EntityKind?, measured: Double, heuristic: Double, foreground: Double, background: Double, active: Double, peak: Double, confidence: AttributionConfidence, cause: String) throws {
        try execute("""
        INSERT INTO battery_attribution(window_start, item_id, display_name, category, kind,
          measured_joules, heuristic_joules, foreground_joules, background_joules,
          active_seconds, peak_watts, confidence_rank, cause)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, binds: [.double(start), .text(id), .text(name), .text(category.rawValue), kind.map { .text($0.rawValue) } ?? .null, .double(measured), .double(heuristic), .double(foreground), .double(background), .double(active), .double(peak), .int64(Int64(confidenceRank(confidence))), .text(cause)])
    }

    private func average(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    private func enforceSizeCap(now: Date) throws {
        guard databaseBytes() > policy.maximumDatabaseBytes else { return }
        let timestamp = now.timeIntervalSince1970
        try transaction {
            try execute("DELETE FROM samples_raw WHERE timestamp < ?", binds: [.double(timestamp - 10 * 60)])
            try execute("DELETE FROM system_samples WHERE timestamp < ?", binds: [.double(timestamp - 10 * 60)])
        }
        try execute("PRAGMA incremental_vacuum(1000)")
        try execute("PRAGMA wal_checkpoint(TRUNCATE)")
        if databaseBytes() > policy.maximumDatabaseBytes {
            try transaction {
                try execute("DELETE FROM minutes WHERE bucket_start < ?", binds: [.double(timestamp - 24 * 60 * 60)])
                try execute("DELETE FROM system_minutes WHERE bucket_start < ?", binds: [.double(timestamp - 24 * 60 * 60)])
            }
            try execute("PRAGMA incremental_vacuum(1000)")
            try execute("PRAGMA wal_checkpoint(TRUNCATE)")
        }
        if databaseBytes() > policy.maximumDatabaseBytes {
            try transaction {
                try execute("DELETE FROM hours WHERE bucket_start < ?", binds: [.double(timestamp - 7 * 24 * 60 * 60)])
                try execute("DELETE FROM system_hours WHERE bucket_start < ?", binds: [.double(timestamp - 7 * 24 * 60 * 60)])
                try execute("DELETE FROM battery_windows_hours WHERE bucket_start < ?", binds: [.double(timestamp - 7 * 24 * 60 * 60)])
                try execute("DELETE FROM battery_attribution_hours WHERE bucket_start < ?", binds: [.double(timestamp - 7 * 24 * 60 * 60)])
            }
            try execute("PRAGMA incremental_vacuum(1000)")
            try execute("PRAGMA wal_checkpoint(TRUNCATE)")
        }
        var dayTrimAttempts = 0
        while databaseBytes() > policy.maximumDatabaseBytes, dayTrimAttempts < 24 {
            let before = try count("days") + count("system_days") + count("battery_attribution_days")
            guard before > 0 else { break }
            try transaction {
                try execute("DELETE FROM days WHERE bucket_start IN (SELECT bucket_start FROM days ORDER BY bucket_start LIMIT 1000)")
                try execute("DELETE FROM system_days WHERE bucket_start IN (SELECT bucket_start FROM system_days ORDER BY bucket_start LIMIT 30)")
                try execute("DELETE FROM battery_windows_days WHERE bucket_start IN (SELECT bucket_start FROM battery_windows_days ORDER BY bucket_start LIMIT 30)")
                try execute("DELETE FROM battery_attribution_days WHERE bucket_start IN (SELECT bucket_start FROM battery_attribution_days ORDER BY bucket_start LIMIT 1000)")
            }
            try execute("PRAGMA incremental_vacuum(1000)")
            try execute("PRAGMA wal_checkpoint(TRUNCATE)")
            dayTrimAttempts += 1
        }
    }

    private func loadPreviousState() throws {
        let statement = try Statement(database: requiredDatabase(), sql: "SELECT timestamp, on_battery FROM system_samples ORDER BY timestamp DESC LIMIT 1")
        if try statement.stepRow() {
            previousTimestamp = Date(timeIntervalSince1970: statement.double(0))
            previousOnBattery = statement.int(1) != 0
            lastMaintenanceBucket = Int64(statement.double(0) / 60)
        }
        guard let previousTimestamp else { return }
        let entities = try Statement(database: requiredDatabase(), sql: "SELECT entity_id FROM samples_raw WHERE timestamp = ?")
        try entities.bind(.double(previousTimestamp.timeIntervalSince1970), at: 1)
        while try entities.stepRow() {
            if let id = entities.text(0) { previousEntityIDs.insert(id) }
        }
        hasEntityBaseline = !previousEntityIDs.isEmpty
    }

    private func resolved(_ requested: HistoryResolution, duration: TimeInterval) -> HistoryResolution {
        guard requested == .automatic else { return requested }
        if duration <= policy.rawRetention { return .raw }
        if duration <= policy.minuteRetention { return .minute }
        if duration <= policy.hourRetention { return .hour }
        return .day
    }

    private func tableName(for resolution: HistoryResolution, system: Bool) -> String {
        switch (system, resolution) {
        case (false, .raw): return "samples_raw"
        case (false, .minute): return "minutes"
        case (false, .hour): return "hours"
        case (false, .day): return "days"
        case (true, .raw): return "system_samples"
        case (true, .minute): return "system_minutes"
        case (true, .hour): return "system_hours"
        case (true, .day): return "system_days"
        case (_, .automatic): return system ? "system_samples" : "samples_raw"
        }
    }

    private func validated(_ range: HistoryRange) throws -> HistoryRange {
        guard range.end > range.start else { throw HistoryStoreError.invalidRange }
        return range
    }

    private func count(_ table: String) throws -> Int {
        Int(try scalarInt64("SELECT COUNT(*) FROM \(table)") ?? 0)
    }

    /// Bytes of live data: in-use pages of the main file plus the WAL. Free-list
    /// pages are excluded on purpose. Measuring raw file size made the cap fire on
    /// space SQLite had already freed, so every maintenance pass evicted real
    /// history (raw → 10 min, minutes → 24 h, hours → 7 d, every day row) without
    /// ever getting the file under the cap.
    private func databaseBytes() -> UInt64 {
        let wal = (try? URL(fileURLWithPath: url.path + "-wal").resourceValues(forKeys: [.fileSizeKey]).fileSize)
            .map(UInt64.init) ?? 0
        guard let pages = try? scalarInt64("PRAGMA page_count"),
              let free = try? scalarInt64("PRAGMA freelist_count"),
              let pageSize = try? scalarInt64("PRAGMA page_size") else {
            let main = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(UInt64.init) ?? 0
            return main &+ wal
        }
        return UInt64(max(0, pages - free) * pageSize) &+ wal
    }

    private func localDayStart(for date: Date) -> Date {
        Calendar.current.startOfDay(for: date)
    }

    private func requiredDatabase() throws -> OpaquePointer {
        guard let database else { throw HistoryStoreError.sqlite(message: "database is closed", code: SQLITE_MISUSE) }
        return database
    }

    private func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func execute(_ sql: String, binds: [BindValue] = []) throws {
        if binds.isEmpty && sql.contains(";") {
            var errorMessage: UnsafeMutablePointer<CChar>?
            let result = sqlite3_exec(try requiredDatabase(), sql, nil, nil, &errorMessage)
            guard result == SQLITE_OK else {
                let message = errorMessage.map { String(cString: $0) } ?? "unknown error"
                sqlite3_free(errorMessage)
                throw HistoryStoreError.sqlite(message: message, code: result)
            }
            return
        }
        let statement = try Statement(database: requiredDatabase(), sql: sql)
        for (offset, bind) in binds.enumerated() { try statement.bind(bind, at: Int32(offset + 1)) }
        try statement.stepDone()
    }

    private func scalarText(_ sql: String, binds: [BindValue] = []) throws -> String? {
        let statement = try Statement(database: requiredDatabase(), sql: sql)
        for (offset, bind) in binds.enumerated() { try statement.bind(bind, at: Int32(offset + 1)) }
        return try statement.stepRow() ? statement.text(0) : nil
    }

    private func scalarDouble(_ sql: String) throws -> Double? {
        let statement = try Statement(database: requiredDatabase(), sql: sql)
        guard try statement.stepRow(), statement.columnType(0) != SQLITE_NULL else { return nil }
        return statement.double(0)
    }

    private func scalarInt64(_ sql: String) throws -> Int64? {
        let statement = try Statement(database: requiredDatabase(), sql: sql)
        guard try statement.stepRow(), statement.columnType(0) != SQLITE_NULL else { return nil }
        return statement.int64(0)
    }

    private func clampedInt64(_ value: UInt64) -> Int64 {
        value > UInt64(Int64.max) ? Int64.max : Int64(value)
    }
}

private enum BindValue {
    case null
    case int64(Int64)
    case double(Double)
    case text(String)
}

private final class Statement {
    private let database: OpaquePointer
    private var handle: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(database: OpaquePointer, sql: String) throws {
        self.database = database
        let result = sqlite3_prepare_v2(database, sql, -1, &handle, nil)
        guard result == SQLITE_OK else {
            throw HistoryStoreError.sqlite(message: String(cString: sqlite3_errmsg(database)), code: result)
        }
    }

    deinit { sqlite3_finalize(handle) }

    func bind(_ value: BindValue, at index: Int32) throws {
        let result: Int32
        switch value {
        case .null: result = sqlite3_bind_null(handle, index)
        case .int64(let value): result = sqlite3_bind_int64(handle, index, value)
        case .double(let value): result = sqlite3_bind_double(handle, index, value)
        case .text(let value): result = sqlite3_bind_text(handle, index, value, -1, Self.transient)
        }
        guard result == SQLITE_OK else {
            throw HistoryStoreError.sqlite(message: String(cString: sqlite3_errmsg(database)), code: result)
        }
    }

    func stepDone() throws {
        while true {
            let result = sqlite3_step(handle)
            if result == SQLITE_DONE { return }
            if result == SQLITE_ROW { continue }
            throw HistoryStoreError.sqlite(message: String(cString: sqlite3_errmsg(database)), code: result)
        }
    }

    func stepRow() throws -> Bool {
        let result = sqlite3_step(handle)
        if result == SQLITE_ROW { return true }
        if result == SQLITE_DONE { return false }
        throw HistoryStoreError.sqlite(message: String(cString: sqlite3_errmsg(database)), code: result)
    }

    func reset() {
        sqlite3_reset(handle)
        sqlite3_clear_bindings(handle)
    }

    func text(_ column: Int32) -> String? {
        sqlite3_column_text(handle, column).map { String(cString: $0) }
    }
    func double(_ column: Int32) -> Double { sqlite3_column_double(handle, column) }
    func optionalDouble(_ column: Int32) -> Double? { columnType(column) == SQLITE_NULL ? nil : double(column) }
    func int(_ column: Int32) -> Int { Int(sqlite3_column_int64(handle, column)) }
    func optionalInt(_ column: Int32) -> Int? { columnType(column) == SQLITE_NULL ? nil : int(column) }
    func int64(_ column: Int32) -> Int64 { sqlite3_column_int64(handle, column) }
    func uint64(_ column: Int32) -> UInt64 { UInt64(max(0, int64(column))) }
    func columnType(_ column: Int32) -> Int32 { sqlite3_column_type(handle, column) }
}

private func pressureRank(_ value: MemoryPressureLevel) -> Int {
    switch value { case .unknown: 0; case .normal: 1; case .warning: 2; case .critical: 3 }
}

private func confidenceRank(_ value: AttributionConfidence) -> Int {
    switch value { case .high: 1; case .medium: 2; case .low: 3 }
}

private func confidence(from rank: Int) -> AttributionConfidence {
    switch rank { case 1: .high; case 2: .medium; default: .low }
}

private func pressure(from rank: Int) -> MemoryPressureLevel {
    switch rank { case 1: .normal; case 2: .warning; case 3: .critical; default: .unknown }
}

private func thermalRank(_ value: ThermalLevel) -> Int {
    switch value { case .unknown: 0; case .nominal: 1; case .fair: 2; case .serious: 3; case .critical: 4 }
}

private func thermal(from rank: Int) -> ThermalLevel {
    switch rank { case 1: .nominal; case 2: .fair; case 3: .serious; case 4: .critical; default: .unknown }
}
