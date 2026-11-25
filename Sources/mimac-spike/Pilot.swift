import Foundation
import MimacCore

struct EnergyPilotResult {
    let startedAt: Date
    let duration: TimeInterval
    let samples: Int
    let gaugeJoules: Double
    let processJoules: Double
    let measuredCoverage: Double
    let residualJoules: Double
    let interrupted: Bool

    var reconciliationError: Double? {
        guard gaugeJoules > 0 else { return nil }
        return abs(gaugeJoules - processJoules) / gaugeJoules
    }
}

enum EnergyPilot {
    private struct ProcessKey: Hashable {
        let pid: Int32
        let start: UInt64
    }

    private static func counters() -> [ProcessKey: UInt64] {
        var result: [ProcessKey: UInt64] = [:]
        for pid in ProcAPI.allPids() {
            guard let ru = ProcAPI.rusage(for: pid) else { continue }
            let energy = ru.energy_nj > 0 ? ru.energy_nj : ru.billed_energy
            result[ProcessKey(pid: pid, start: ru.proc_start_abstime)] = energy
        }
        return result
    }

    static func run(seconds: TimeInterval, interval: TimeInterval = 1) -> EnergyPilotResult {
        let startedAt = Date()
        let deadline = startedAt.addingTimeInterval(seconds)
        var previousBattery = GasGauge.sample()
        var previousCounters = counters()
        var gaugeJoules = 0.0
        var processJoules = 0.0
        var samples = previousBattery == nil ? 0 : 1

        while Date() < deadline {
            Thread.sleep(forTimeInterval: min(interval, max(0, deadline.timeIntervalSinceNow)))
            let nowBattery = GasGauge.sample()
            let nowCounters = counters()

            if let before = previousBattery, let after = nowBattery {
                let dt = after.timestamp.timeIntervalSince(before.timestamp)
                let beforeDischarge = max(0, -before.watts)
                let afterDischarge = max(0, -after.watts)
                gaugeJoules += (beforeDischarge + afterDischarge) * 0.5 * dt
                samples += 1
            }

            for (key, value) in nowCounters {
                guard let old = previousCounters[key], value >= old else { continue }
                processJoules += Double(value - old) / 1e9
            }
            previousBattery = nowBattery
            previousCounters = nowCounters
        }

        let coverage = gaugeJoules > 0 ? processJoules / gaugeJoules : 0
        return EnergyPilotResult(
            startedAt: startedAt,
            duration: Date().timeIntervalSince(startedAt),
            samples: samples,
            gaugeJoules: gaugeJoules,
            processJoules: processJoules,
            measuredCoverage: coverage,
            residualJoules: gaugeJoules - processJoules,
            interrupted: false
        )
    }
}
