import Foundation
import XCTest
import MimacHistory
import MimacIdentity

final class HistoryStoreTests: XCTestCase {
    func testPersistsQueriesAndRollsUpEntityAndSystemSamples() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mimac-history-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try HistoryStore(url: directory.appendingPathComponent("history.sqlite"))
        let base = floor(1_700_000_000.0 / 60) * 60

        try store.persist(sample(at: base + 5, sequence: 1, energy: 1))
        try store.persist(sample(at: base + 35, sequence: 2, energy: 2))
        try store.persist(sample(at: base + 65, sequence: 3, energy: 3))

        let rawRange = HistoryRange(start: Date(timeIntervalSince1970: base), end: Date(timeIntervalSince1970: base + 120), resolution: .raw)
        let raw = try store.entityTimeline(EntityTimelineRequest(entityID: "entity-test", range: rawRange))
        XCTAssertEqual(raw.points.count, 3)
        XCTAssertEqual(raw.points.reduce(0) { $0 + $1.energyJoules }, 6, accuracy: 0.0001)

        let minuteRange = HistoryRange(start: Date(timeIntervalSince1970: base), end: Date(timeIntervalSince1970: base + 120), resolution: .minute)
        let minute = try store.entityTimeline(EntityTimelineRequest(entityID: "entity-test", range: minuteRange))
        XCTAssertEqual(minute.points.count, 1)
        XCTAssertEqual(minute.points[0].durationSeconds, 60, accuracy: 0.0001)
        XCTAssertEqual(minute.points[0].energyJoules, 3, accuracy: 0.0001)

        let top = try store.topEntities(TopEntitiesRequest(range: rawRange, metric: .energyJoules, limit: 5))
        XCTAssertEqual(top.first?.entityID, "entity-test")
        XCTAssertEqual(top.first?.value ?? 0, 6, accuracy: 0.0001)

        let system = try store.systemTimeline(minuteRange)
        XCTAssertEqual(system.points.count, 1)
        XCTAssertEqual(system.points[0].averageBatteryWatts ?? 0, 8, accuracy: 0.0001)

        let health = try store.health()
        XCTAssertEqual(health.rawEntitySamples, 3)
        XCTAssertEqual(health.rawSystemSamples, 3)
        XCTAssertEqual(health.minuteRollups, 1)

        try store.performMaintenance(now: Date(timeIntervalSince1970: base + 120))
        try store.performMaintenance(now: Date(timeIntervalSince1970: base + 120))
        let rerolled = try store.entityTimeline(EntityTimelineRequest(entityID: "entity-test", range: minuteRange))
        XCTAssertEqual(rerolled.points.count, 2)
        XCTAssertEqual(rerolled.points.reduce(0) { $0 + $1.energyJoules }, 6, accuracy: 0.0001)
    }

    func testRecordsSampleGapAndPowerTransitionEvents() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mimac-events-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try HistoryStore(url: directory.appendingPathComponent("history.sqlite"))
        let base = floor(1_700_000_000.0 / 60) * 60

        try store.persist(sample(at: base, sequence: 1, energy: 1, onBattery: true))
        try store.persist(sample(at: base + 180, sequence: 2, energy: 1, onBattery: false))

        XCTAssertEqual(try store.health().eventCount, 2)
    }

    func testRetentionEvictsRawOnlyAfterCreatingMinuteRollup() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mimac-retention-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let policy = HistoryPolicy(rawRetention: 60, minuteRetention: 600, hourRetention: 3_600, maximumDatabaseBytes: 50 * 1_048_576)
        let store = try HistoryStore(url: directory.appendingPathComponent("history.sqlite"), policy: policy)
        let base = floor(1_700_000_000.0 / 60) * 60

        try store.persist(sample(at: base, sequence: 1, energy: 1))
        try store.persist(sample(at: base + 120, sequence: 2, energy: 2))

        let health = try store.health()
        XCTAssertEqual(health.rawEntitySamples, 1)
        XCTAssertEqual(health.minuteRollups, 1)
    }

    func testRestartBaselineDoesNotCreateFalseEntityStopStartEvents() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mimac-restart-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.sqlite")
        let base = floor(1_700_000_000.0 / 60) * 60

        var firstStore: HistoryStore? = try HistoryStore(url: url)
        try firstStore?.persist(sample(at: base, sequence: 1, energy: 1))
        firstStore = nil

        let restarted = try HistoryStore(url: url)
        try restarted.persist(sample(at: base + 5, sequence: 1, energy: 0, includeEntity: false))
        try restarted.persist(sample(at: base + 10, sequence: 2, energy: 1))
        XCTAssertEqual(try restarted.health().eventCount, 0)
    }

    func testBatteryAttributionReconcilesAndCarriesConfidence() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mimac-battery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try HistoryStore(url: directory.appendingPathComponent("history.sqlite"))
        let base = floor(1_700_000_000.0 / 60) * 60
        try store.persist(sample(at: base + 5, sequence: 1, energy: 1))
        try store.persist(sample(at: base + 35, sequence: 2, energy: 2))
        try store.persist(sample(at: base + 65, sequence: 3, energy: 1))

        let range = HistoryRange(start: Date(timeIntervalSince1970: base), end: Date(timeIntervalSince1970: base + 60), resolution: .minute)
        let report = try store.batteryHistory(BatteryHistoryRequest(range: range))
        XCTAssertEqual(report.timeline.count, 1)
        XCTAssertEqual(report.totalDrainJoules, 240, accuracy: 0.001)
        XCTAssertEqual(report.rows.reduce(0) { $0 + $1.totalJoules }, report.totalDrainJoules, accuracy: 0.001)
        XCTAssertTrue(report.rows.contains { $0.id == "entity-test" && $0.confidence == .high })
        XCTAssertTrue(report.rows.contains { $0.category == .unattributed })
        XCTAssertGreaterThan(report.totalBatteryPercent, 0)
    }

    func testBatteryAttributionRollsUpToHourAndDayTiersWithWorstOfConfidence() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mimac-battery-rollup-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try HistoryStore(url: directory.appendingPathComponent("history.sqlite"))
        let dayStart = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000)).timeIntervalSince1970
        // Hour buckets are UTC-aligned; pick one inside the local day even in
        // half-hour-offset timezones.
        let hourStart = floor((dayStart + 3 * 3600) / 3600) * 3600
        var sequence: UInt64 = 1

        // Three attributed minute windows inside one hour; the third has a runaway
        // measured counter so its entity row is low-confidence.
        for minute in 0..<3 {
            let energy: Double = minute == 2 ? 5_000 : 1
            let minuteStart = hourStart + Double(minute) * 60
            try store.persist(sample(at: minuteStart + 5, sequence: sequence, energy: energy)); sequence += 1
            try store.persist(sample(at: minuteStart + 35, sequence: sequence, energy: energy)); sequence += 1
        }
        try store.performMaintenance(now: Date(timeIntervalSince1970: hourStart + 2 * 3600))

        let hourRange = HistoryRange(start: Date(timeIntervalSince1970: hourStart), end: Date(timeIntervalSince1970: hourStart + 3600), resolution: .hour)
        let hourReport = try store.batteryHistory(BatteryHistoryRequest(range: hourRange))
        XCTAssertEqual(hourReport.resolution, .hour)
        XCTAssertEqual(hourReport.timeline.count, 1)
        XCTAssertEqual(hourReport.totalDrainJoules, 720, accuracy: 0.001)
        XCTAssertEqual(hourReport.attributedDurationSeconds, 90, accuracy: 0.001)
        XCTAssertEqual(hourReport.rows.reduce(0) { $0 + $1.totalJoules }, 720, accuracy: 0.001)
        XCTAssertTrue(hourReport.rows.contains { $0.category == .unattributed })
        XCTAssertTrue(hourReport.rows.contains { $0.category == .display })

        // Worst-of confidence: two high-confidence windows plus one low-confidence one.
        let entityRow = try XCTUnwrap(hourReport.rows.first { $0.id == "entity-test" })
        XCTAssertEqual(entityRow.confidence, .low)

        // Rolled totals must match the minute-tier answer for the same range.
        let minuteReport = try store.batteryHistory(BatteryHistoryRequest(range: HistoryRange(start: hourRange.start, end: hourRange.end, resolution: .minute)))
        XCTAssertEqual(hourReport.totalDrainJoules, minuteReport.totalDrainJoules, accuracy: 0.001)
        XCTAssertEqual(hourReport.totalBatteryPercent, minuteReport.totalBatteryPercent, accuracy: 0.001)

        try store.performMaintenance(now: Date(timeIntervalSince1970: dayStart + 86400 + 60))
        let dayRange = HistoryRange(start: Date(timeIntervalSince1970: dayStart), end: Date(timeIntervalSince1970: dayStart + 86400), resolution: .day)
        let dayReport = try store.batteryHistory(BatteryHistoryRequest(range: dayRange))
        XCTAssertEqual(dayReport.resolution, .day)
        let attributedDays = dayReport.timeline.filter { $0.drainJoules != nil }
        XCTAssertEqual(attributedDays.count, 1)
        XCTAssertEqual(attributedDays[0].drainJoules ?? 0, 720, accuracy: 0.001)
        XCTAssertEqual(dayReport.totalDrainJoules, 720, accuracy: 0.001)
        XCTAssertEqual(dayReport.totalBatteryPercent, minuteReport.totalBatteryPercent, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(dayReport.rows.first { $0.id == "entity-test" }).confidence, .low)
    }

    func testBatteryDayRollupSplitsAcrossLocalMidnight() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mimac-battery-midnight-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try HistoryStore(url: directory.appendingPathComponent("history.sqlite"))
        let dayStart = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000)).timeIntervalSince1970
        var sequence: UInt64 = 1

        // One attributed window at 23:00 and one at 00:00 the next local day.
        for windowStart in [dayStart + 23 * 3600, dayStart + 24 * 3600] {
            try store.persist(sample(at: windowStart + 5, sequence: sequence, energy: 1)); sequence += 1
            try store.persist(sample(at: windowStart + 35, sequence: sequence, energy: 1)); sequence += 1
        }
        try store.performMaintenance(now: Date(timeIntervalSince1970: dayStart + 2 * 86400))

        let range = HistoryRange(start: Date(timeIntervalSince1970: dayStart), end: Date(timeIntervalSince1970: dayStart + 2 * 86400), resolution: .day)
        let report = try store.batteryHistory(BatteryHistoryRequest(range: range))
        let attributed = report.timeline.filter { $0.drainJoules != nil }
        guard attributed.count == 2 else {
            return XCTFail("expected one attributed day on each side of local midnight, got \(attributed.count)")
        }
        XCTAssertEqual(attributed[0].timestamp.timeIntervalSince1970, dayStart, accuracy: 0.001)
        XCTAssertEqual(attributed[1].timestamp.timeIntervalSince1970, dayStart + 86400, accuracy: 0.001)
        XCTAssertEqual(attributed[0].drainJoules ?? 0, 240, accuracy: 0.001)
        XCTAssertEqual(attributed[1].drainJoules ?? 0, 240, accuracy: 0.001)
    }

    func testSizeCapEvictsBatteryRollupTiersWithoutBreakingStore() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mimac-battery-cap-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let policy = HistoryPolicy(maximumDatabaseBytes: 1)
        let store = try HistoryStore(url: directory.appendingPathComponent("history.sqlite"), policy: policy)
        let dayStart = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000)).timeIntervalSince1970

        try store.persist(sample(at: dayStart + 5, sequence: 1, energy: 1))
        try store.persist(sample(at: dayStart + 35, sequence: 2, energy: 1))
        try store.performMaintenance(now: Date(timeIntervalSince1970: dayStart + 86400 + 60))

        let health = try store.health()
        XCTAssertEqual(health.batteryDayRollups, 0)
        // The store must stay usable after aggressive eviction.
        try store.persist(sample(at: dayStart + 86400 + 65, sequence: 3, energy: 1))
    }

    func testHealthReportsBatteryCountsAndMinuteFillRate() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mimac-battery-health-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try HistoryStore(url: directory.appendingPathComponent("history.sqlite"))
        let base = floor(Date().timeIntervalSince1970 / 60) * 60 - 180

        try store.persist(sample(at: base + 5, sequence: 1, energy: 1))
        try store.persist(sample(at: base + 35, sequence: 2, energy: 1))
        try store.persist(sample(at: base + 65, sequence: 3, energy: 1))
        try store.performMaintenance(now: Date(timeIntervalSince1970: base + 2 * 3600))

        let health = try store.health()
        XCTAssertGreaterThan(health.batteryWindows, 0)
        XCTAssertGreaterThan(health.batteryHourRollups, 0)
        XCTAssertGreaterThan(health.minuteFillRatePercent24h, 0)
    }

    func testEntityUsageReturnsDurationWeightedAverages() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mimac-usage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try HistoryStore(url: directory.appendingPathComponent("history.sqlite"))
        let base = floor(1_700_000_000.0 / 60) * 60

        try store.persist(sample(at: base + 5, sequence: 1, energy: 3))
        try store.persist(sample(at: base + 35, sequence: 2, energy: 6))

        let range = HistoryRange(start: Date(timeIntervalSince1970: base), end: Date(timeIntervalSince1970: base + 600))
        let summaries = try store.entityUsage(EntityUsageRequest(range: range))
        XCTAssertEqual(summaries.count, 1)
        let summary = try XCTUnwrap(summaries.first)
        XCTAssertEqual(summary.entityID, "entity-test")
        // 2 × 7.5 CPU-seconds spread over the whole 600 s window, like power.
        XCTAssertEqual(summary.averageCPUPercent, 2.5, accuracy: 0.01)
        XCTAssertEqual(summary.energyJoules, 9, accuracy: 0.0001)
        XCTAssertEqual(summary.activeSeconds, 60, accuracy: 0.0001)
        XCTAssertEqual(summary.averagePowerWatts, 9.0 / 600, accuracy: 0.0001)
    }

    func testBackfilledCapacityRerollsClosedHourBuckets() throws {
        // macOS 27 hid the capacity keys, so windows were rolled with no capacity
        // and their hour buckets read 0%. Once capacity is known again and the rows
        // are backfilled, closed buckets outside the normal lookback must re-roll.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mimac-battery-reroll-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try HistoryStore(url: directory.appendingPathComponent("history.sqlite"))
        let hourStart = floor(1_700_000_000.0 / 3600) * 3600
        var sequence: UInt64 = 1
        for minute in 0..<3 {
            let minuteStart = hourStart + Double(minute) * 60
            try store.persist(sample(at: minuteStart + 5, sequence: sequence, energy: 1, capacityWh: nil)); sequence += 1
            try store.persist(sample(at: minuteStart + 35, sequence: sequence, energy: 1, capacityWh: nil)); sequence += 1
        }
        try store.performMaintenance(now: Date(timeIntervalSince1970: hourStart + 2 * 3600))
        let hourRange = HistoryRange(start: Date(timeIntervalSince1970: hourStart), end: Date(timeIntervalSince1970: hourStart + 3600), resolution: .hour)
        XCTAssertEqual(try store.batteryHistory(BatteryHistoryRequest(range: hourRange)).totalBatteryPercent, 0, accuracy: 0.0001)

        // Capacity reappears long after the bucket left the rollup lookback.
        let later = hourStart + 8 * 3600
        try store.persist(sample(at: later + 5, sequence: sequence, energy: 1, onBattery: false))
        try store.performMaintenance(now: Date(timeIntervalSince1970: later + 120))

        let rerolled = try store.batteryHistory(BatteryHistoryRequest(range: hourRange))
        let minute = try store.batteryHistory(BatteryHistoryRequest(range: HistoryRange(start: hourRange.start, end: hourRange.end, resolution: .minute)))
        XCTAssertGreaterThan(rerolled.totalBatteryPercent, 0)
        XCTAssertEqual(rerolled.totalBatteryPercent, minute.totalBatteryPercent, accuracy: 0.0001)
        XCTAssertGreaterThan(rerolled.rows.reduce(0) { $0 + $1.batteryPercent }, 0)
    }

    func testAveragedWindowsIncludeHardwareRows() throws {
        // The live table adds Memory & chip and Display & rest of Mac so its
        // rows sum to the draw; averaged windows have to show them too.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mimac-hardware-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try HistoryStore(url: directory.appendingPathComponent("history.sqlite"))
        let base = floor(1_700_000_000.0 / 3600) * 3600
        let breakdown = PowerBreakdown(source: .rails, totalWatts: 8, cpuRailWatts: 1, gpuRailWatts: 0.5, chipWatts: 1.5, restOfMacWatts: 5)
        // 10 min covered by samples; the first 5 min predate schema 6 (no breakdown).
        for index in 0..<20 {
            try store.persist(sample(at: base + Double(index) * 30 + 5, sequence: UInt64(index + 1), energy: 1,
                                     breakdown: index < 10 ? nil : breakdown))
        }
        let range = HistoryRange(start: Date(timeIntervalSince1970: base), end: Date(timeIntervalSince1970: base + 600))
        let rows = Dictionary(uniqueKeysWithValues: try store.entityUsage(EntityUsageRequest(range: range)).map { ($0.entityID, $0) })
        let chip = try XCTUnwrap(rows[SyntheticEntity.chipID])
        let rest = try XCTUnwrap(rows[SyntheticEntity.restOfMacID])
        XCTAssertEqual(rest.displayName, "Display & rest of Mac")
        XCTAssertEqual(chip.energyJoules, 1.5 * 30 * 10, accuracy: 0.001)
        XCTAssertEqual(chip.averagePowerWatts, 0.75, accuracy: 0.001)
        XCTAssertEqual(rest.averagePowerWatts, 2.5, accuracy: 0.001)
        XCTAssertEqual(rest.activeSeconds, 300, accuracy: 0.001)

        // The hour window reads the minute tier; it must agree.
        try store.performMaintenance(now: Date(timeIntervalSince1970: base + 3 * 3600))
        let hour = HistoryRange(start: Date(timeIntervalSince1970: base), end: Date(timeIntervalSince1970: base + 3600))
        let hourRows = Dictionary(uniqueKeysWithValues: try store.entityUsage(EntityUsageRequest(range: hour)).map { ($0.entityID, $0) })
        XCTAssertEqual(try XCTUnwrap(hourRows[SyntheticEntity.restOfMacID]).energyJoules, 5 * 30 * 10, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(hourRows[SyntheticEntity.chipID]).energyJoules, 1.5 * 30 * 10, accuracy: 0.001)
    }

    func testShortCPUBurstDoesNotOutrankSustainedLoad() throws {
        // A 15-second burst at 100% used to average to 100% over its own lifetime
        // and top a 10-minute window over an app at a steady 20%.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mimac-burst-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try HistoryStore(url: directory.appendingPathComponent("history.sqlite"))
        let base = floor(1_700_000_000.0 / 60) * 60
        for index in 0..<20 {
            var extras = [entity(id: "steady", cpuPercent: 20, cpuSeconds: 6, energy: 1)]
            if index == 10 { extras.append(entity(id: "burst", cpuPercent: 50, cpuSeconds: 15, energy: 0.5)) }
            try store.persist(sample(at: base + Double(index) * 30 + 5, sequence: UInt64(index + 1), energy: 0, includeEntity: false, extraEntities: extras))
        }
        let range = HistoryRange(start: Date(timeIntervalSince1970: base), end: Date(timeIntervalSince1970: base + 600))
        let summaries = Dictionary(uniqueKeysWithValues: try store.entityUsage(EntityUsageRequest(range: range)).map { ($0.entityID, $0) })
        let steady = try XCTUnwrap(summaries["steady"])
        let burst = try XCTUnwrap(summaries["burst"])
        XCTAssertEqual(steady.averageCPUPercent, 20, accuracy: 0.01)
        XCTAssertEqual(burst.averageCPUPercent, 2.5, accuracy: 0.01)
        XCTAssertEqual(burst.activeSeconds, 30, accuracy: 0.01)
    }

    func testUnreadableProcessesRowIsNeverGivenHeuristicEnergy() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mimac-unreadable-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try HistoryStore(url: directory.appendingPathComponent("history.sqlite"))
        let base = floor(1_700_000_000.0 / 60) * 60
        let unreadable = entity(id: SyntheticEntity.unreadableProcessesID, cpuPercent: 60, cpuSeconds: 18, energy: 0)
        try store.persist(sample(at: base + 5, sequence: 1, energy: 1, extraEntities: [unreadable]))
        try store.persist(sample(at: base + 35, sequence: 2, energy: 1, extraEntities: [unreadable]))
        try store.performMaintenance(now: Date(timeIntervalSince1970: base + 120))

        let range = HistoryRange(start: Date(timeIntervalSince1970: base), end: Date(timeIntervalSince1970: base + 60), resolution: .minute)
        let report = try store.batteryHistory(BatteryHistoryRequest(range: range))
        XCTAssertGreaterThan(report.totalDrainJoules, 0)
        XCTAssertFalse(report.rows.contains { $0.id == SyntheticEntity.unreadableProcessesID })
        XCTAssertTrue(report.rows.contains { $0.category == .unattributed })
    }

    private func entity(id: String, cpuPercent: Double, cpuSeconds: Double, energy: Double) -> EntityTelemetry {
        EntityTelemetry(
            entityID: id, displayName: id, kind: .app, project: nil, processIDs: [], processCount: 1,
            cpuPercent: cpuPercent, cpuSeconds: cpuSeconds, pCoreCPUSeconds: 0, residentBytes: 1_000_000,
            diskReadBytes: 0, diskWrittenBytes: 0, wakeups: 0, energyJoules: energy, powerWatts: energy / 30,
            confidence: .high, groupedAutomatically: false
        )
    }

    private func sample(at timestamp: TimeInterval, sequence: UInt64, energy: Double, onBattery: Bool = true, includeEntity: Bool = true, capacityWh: Double? = 50, extraEntities: [EntityTelemetry] = [], breakdown: PowerBreakdown? = nil) -> CollectorTelemetry {
        let entity = EntityTelemetry(
            entityID: "entity-test",
            displayName: "Test Entity",
            kind: .app,
            project: "Fixture",
            processIDs: [42],
            processCount: 1,
            cpuPercent: 25,
            cpuSeconds: 7.5,
            pCoreCPUSeconds: 3,
            residentBytes: 100_000_000,
            diskReadBytes: 1_000,
            diskWrittenBytes: 2_000,
            wakeups: 4,
            energyJoules: energy,
            powerWatts: energy / 30,
            activityLevel: .medium,
            confidence: .high,
            groupedAutomatically: false
        )
        return CollectorTelemetry(
            sequence: sequence,
            timestamp: Date(timeIntervalSince1970: timestamp),
            sampleIntervalSeconds: 30,
            samplingMode: .idleOnBattery,
            userIdleSeconds: 120,
            onBattery: onBattery,
            batteryWatts: 8,
            powerBreakdown: breakdown,
            batteryPercent: 75,
            batteryFullChargeCapacityWh: capacityWh,
            batteryVoltage: 12,
            displayBrightness: 0.5,
            screenOn: true,
            systemCPUPercent: 20,
            systemGPUPercent: 10,
            memoryPressure: .normal,
            diskReadBytesPerSecond: 100,
            diskWrittenBytesPerSecond: 200,
            thermalState: .nominal,
            collectorCPUPercent: 0.2,
            collectorResidentBytes: 10_000_000,
            processesObserved: 1,
            processes: [],
            entities: (includeEntity ? [entity] : []) + extraEntities,
            workloads: [],
            errors: []
        )
    }
}
