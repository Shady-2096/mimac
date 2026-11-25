import XCTest
@testable import MimacIdentity

final class PowerAttributionTests: XCTestCase {
    /// Every joule of the whole-Mac rail lands in exactly one row.
    private func total(_ split: PowerAttribution.Split, readableCPUJoules: Double, interval: Double) -> Double {
        let readable = readableCPUJoules * split.readableCPUScale + split.gpuJoulesByPID.values.reduce(0, +)
        let unreadable = split.unreadableCPUJoules + split.unreadableGPUJoules
        let buckets = ((split.breakdown.chipWatts ?? 0) + split.breakdown.restOfMacWatts) * interval
        return readable + unreadable + buckets
    }

    func testPartsSumToTheWholeMacRail() {
        let rails = PowerAttribution.Rails(total: 8, chip: 3, cpu: 1.5, gpu: 0.8)
        let split = PowerAttribution.split(
            rails: rails,
            intervalSeconds: 2,
            readableCPUJoules: 2, // 1 W of the 1.5 W CPU rail
            gpuPercentByPID: [10: 30, 20: 10, 99: 40], // pid 99 is unreadable
            readablePIDs: [10, 20]
        )
        XCTAssertEqual(split.readableCPUScale, 1)
        XCTAssertEqual(split.unreadableCPUJoules, 1, accuracy: 1e-9) // (1.5 - 1) W × 2 s
        XCTAssertEqual(split.gpuJoulesByPID[10]!, 0.6, accuracy: 1e-9) // 0.8 W × 2 s × 30/80
        XCTAssertEqual(split.gpuJoulesByPID[20]!, 0.2, accuracy: 1e-9)
        XCTAssertEqual(split.unreadableGPUJoules, 0.8, accuracy: 1e-9)
        XCTAssertEqual(split.breakdown.chipWatts!, 0.7, accuracy: 1e-9) // 3 - 1.5 - 0.8
        XCTAssertEqual(split.breakdown.restOfMacWatts, 5, accuracy: 1e-9)
        XCTAssertEqual(total(split, readableCPUJoules: 2, interval: 2), 16, accuracy: 1e-9)
    }

    func testCountersAboveTheCPURailAreScaledToFit() {
        let split = PowerAttribution.split(
            rails: .init(total: 10, chip: 5, cpu: 2, gpu: 0),
            intervalSeconds: 1,
            readableCPUJoules: 2.5,
            gpuPercentByPID: [:],
            readablePIDs: []
        )
        XCTAssertEqual(split.readableCPUScale, 0.8, accuracy: 1e-9)
        XCTAssertEqual(split.unreadableCPUJoules, 0, accuracy: 1e-9)
        XCTAssertEqual(total(split, readableCPUJoules: 2.5, interval: 1), 10, accuracy: 1e-9)
    }

    func testIdleGPUPowerStaysWithTheChip() {
        let split = PowerAttribution.split(
            rails: .init(total: 6, chip: 2, cpu: 0.5, gpu: 0.3),
            intervalSeconds: 1,
            readableCPUJoules: 0.2,
            gpuPercentByPID: [10: 0],
            readablePIDs: [10]
        )
        XCTAssertTrue(split.gpuJoulesByPID.isEmpty)
        XCTAssertEqual(split.unreadableGPUJoules, 0)
        XCTAssertEqual(split.breakdown.chipWatts!, 1.5, accuracy: 1e-9) // 2 - 0.5, GPU included
        XCTAssertEqual(total(split, readableCPUJoules: 0.2, interval: 1), 6, accuracy: 1e-9)
    }

    func testInconsistentRailsNeverGoNegative() {
        // A chip reading above the whole-Mac reading (rails sampled a beat
        // apart under a load step) and CPU + GPU above the chip.
        let split = PowerAttribution.split(
            rails: .init(total: 4, chip: 5, cpu: 3, gpu: 3),
            intervalSeconds: 1,
            readableCPUJoules: 1,
            gpuPercentByPID: [10: 50],
            readablePIDs: [10]
        )
        XCTAssertEqual(split.breakdown.restOfMacWatts, 0, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(split.breakdown.chipWatts!, 0)
        XCTAssertEqual(split.gpuJoulesByPID[10]!, 1, accuracy: 1e-9) // GPU clamped to chip − CPU
        XCTAssertEqual(total(split, readableCPUJoules: 1, interval: 1), 4, accuracy: 1e-9)
    }

    func testTotalOnlyLeavesOneUndividedRow() {
        let breakdown = PowerAttribution.totalOnly(totalWatts: 7, entityWatts: 2.5)
        XCTAssertNil(breakdown.chipWatts)
        XCTAssertEqual(breakdown.restOfMacWatts, 4.5, accuracy: 1e-9)
        let rows = breakdown.bucketEntities()
        XCTAssertEqual(rows.map(\.entityID), [SyntheticEntity.restOfMacID])
        XCTAssertEqual(rows.first?.displayName, "Rest of system")
    }

    func testBucketRowsAreFlaggedSoTheyAreNeverTreatedAsProcesses() {
        let rows = PowerBreakdown(source: .rails, totalWatts: 5, cpuRailWatts: 1, gpuRailWatts: 0, chipWatts: 0.4, restOfMacWatts: 3).bucketEntities()
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows.allSatisfy { SyntheticEntity.isPowerBucket($0.entityID) && $0.processIDs.isEmpty })
        XCTAssertFalse(SyntheticEntity.isPowerBucket(SyntheticEntity.unreadableProcessesID))
    }

    func testOlderSnapshotsWithoutABreakdownStillDecode() throws {
        let json = #"{"schemaVersion":5,"sequence":1,"timestamp":0,"sampleIntervalSeconds":2,"samplingMode":"visible","userIdleSeconds":0,"onBattery":false,"screenOn":true,"systemCPUPercent":5,"memoryPressure":"normal","diskReadBytesPerSecond":0,"diskWrittenBytesPerSecond":0,"thermalState":"nominal","collectorCPUPercent":1,"collectorResidentBytes":0,"processesObserved":0,"processes":[],"entities":[],"workloads":[],"errors":[]}"#
        let decoded = try JSONDecoder().decode(CollectorTelemetry.self, from: Data(json.utf8))
        XCTAssertNil(decoded.powerBreakdown)
    }
}
