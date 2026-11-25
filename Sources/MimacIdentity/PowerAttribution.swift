import Foundation

/// Where the whole machine's draw went over one sample. Entity power already
/// carries its CPU and GPU parts; `chipWatts` and `restOfMacWatts` carry the
/// rest, so entities plus those two rows equal `totalWatts`.
public struct PowerBreakdown: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable {
        /// SMC rails for the whole Mac, the chip, the CPU and the GPU.
        case rails
        /// Only the whole-Mac figure was readable, so everything entities do
        /// not account for is one undivided row.
        case totalOnly
    }

    public let source: Source
    public let totalWatts: Double
    /// CPU rail and GPU rail, for the record. Nil with `.totalOnly`.
    public let cpuRailWatts: Double?
    public let gpuRailWatts: Double?
    /// Chip power outside any process: memory, media engines, fabric, the
    /// chip's power delivery, and GPU power while no client holds the GPU.
    /// Nil with `.totalOnly`.
    public let chipWatts: Double?
    /// Outside the chip with `.rails` (display, storage, radios, audio, power
    /// conversion); everything not in an entity with `.totalOnly`.
    public let restOfMacWatts: Double

    public init(source: Source, totalWatts: Double, cpuRailWatts: Double?, gpuRailWatts: Double?, chipWatts: Double?, restOfMacWatts: Double) {
        self.source = source
        self.totalWatts = totalWatts
        self.cpuRailWatts = cpuRailWatts
        self.gpuRailWatts = gpuRailWatts
        self.chipWatts = chipWatts
        self.restOfMacWatts = restOfMacWatts
    }
}

/// Splits measured rail power across processes and hardware so that the parts
/// sum to the whole-Mac rail exactly.
///
/// Verified on Mac17,3 (M5) against spin loads: `PP0b` follows load on the
/// performance cores and `PPbb` on the efficiency cores (six background-QoS
/// spinners moved `PPbb` 0.07 → 0.67 W and left `PP0b` flat), `PP1b` follows
/// GPU load, `PSTR` is the whole Mac. For the chip, `PMVC` (the
/// chip's supply, regulator losses included) rather than `PHPS` (the chip's
/// own rails): at fixed brightness, whole Mac minus `PMVC` went from 3.2 W
/// idle to ~5 W under a 26 W CPU load (system-side conversion loss), while
/// minus `PHPS` went from 4.6 to 9.4 W because it still held the chip's
/// regulator losses. The
/// kernel's per-process CPU energy (`ri_energy_nj`) agrees with `PP0b` to
/// about 10%, so the CPU rail minus the readable processes is a real
/// measurement of the processes Mimac cannot read.
public enum PowerAttribution {
    /// Average rail power over the sample window.
    public struct Rails: Equatable, Sendable {
        public var total: Double
        public var chip: Double
        public var cpu: Double
        public var gpu: Double

        public init(total: Double, chip: Double, cpu: Double, gpu: Double) {
            self.total = total
            self.chip = chip
            self.cpu = cpu
            self.gpu = gpu
        }
    }

    public struct Split: Equatable, Sendable {
        /// Multiplier for readable processes' CPU counters. Below 1 only when
        /// the counters add up to more than the CPU rail, which happens within
        /// measurement noise; the rail wins so the parts still sum.
        public let readableCPUScale: Double
        public let gpuJoulesByPID: [Int32: Double]
        public let unreadableCPUJoules: Double
        public let unreadableGPUJoules: Double
        public let breakdown: PowerBreakdown
    }

    /// - Parameters:
    ///   - readableCPUJoules: sum of the CPU energy counters of processes with
    ///     a row of their own.
    ///   - gpuPercentByPID: GPU-time share for every GPU client, readable or not.
    ///   - readablePIDs: processes with a row of their own; any other GPU
    ///     client's share goes to the unreadable-processes row.
    public static func split(
        rails: Rails,
        intervalSeconds: Double,
        readableCPUJoules: Double,
        gpuPercentByPID: [Int32: Double],
        readablePIDs: Set<Int32>
    ) -> Split {
        let interval = max(0.001, intervalSeconds)
        // Rails are clamped top-down so a noisy reading can never produce a
        // negative remainder: total ≥ chip ≥ CPU + GPU.
        let total = max(0, rails.total)
        let chip = min(max(0, rails.chip), total)
        let cpu = min(max(0, rails.cpu), chip)
        let gpu = min(max(0, rails.gpu), chip - cpu)

        let cpuJoules = cpu * interval
        let readable = max(0, readableCPUJoules)
        let scale = readable > cpuJoules && readable > 0 ? cpuJoules / readable : 1
        let unreadableCPU = max(0, cpuJoules - readable * scale)

        let shares = gpuPercentByPID.filter { $0.value > 0 }
        let shareTotal = shares.values.reduce(0, +)
        var gpuByPID: [Int32: Double] = [:]
        var unreadableGPU = 0.0
        var gpuAttributedWatts = 0.0
        if shareTotal > 0 {
            let gpuJoules = gpu * interval
            for (pid, share) in shares {
                let joules = gpuJoules * share / shareTotal
                if readablePIDs.contains(pid) { gpuByPID[pid] = joules } else { unreadableGPU += joules }
            }
            gpuAttributedWatts = gpu
        }

        return Split(
            readableCPUScale: scale,
            gpuJoulesByPID: gpuByPID,
            unreadableCPUJoules: unreadableCPU,
            unreadableGPUJoules: unreadableGPU,
            breakdown: PowerBreakdown(
                source: .rails,
                totalWatts: total,
                cpuRailWatts: cpu,
                gpuRailWatts: gpu,
                chipWatts: chip - cpu - gpuAttributedWatts,
                restOfMacWatts: total - chip
            )
        )
    }

    /// Without the chip rails, all that can be said is how much of the total
    /// the entities do not cover.
    public static func totalOnly(totalWatts: Double, entityWatts: Double) -> PowerBreakdown {
        let total = max(0, totalWatts)
        return PowerBreakdown(
            source: .totalOnly,
            totalWatts: total,
            cpuRailWatts: nil,
            gpuRailWatts: nil,
            chipWatts: nil,
            restOfMacWatts: max(0, total - entityWatts)
        )
    }
}

extension PowerBreakdown {
    /// The hardware rows for the live table, shaped as entities so they sort
    /// and render beside apps. Built by the app; the collector never persists
    /// them, since battery history models these buckets on its own.
    public func bucketEntities() -> [EntityTelemetry] {
        var rows: [EntityTelemetry] = []
        if let chipWatts {
            rows.append(Self.bucket(id: SyntheticEntity.chipID, name: "Memory & chip", watts: chipWatts))
        }
        rows.append(Self.bucket(
            id: SyntheticEntity.restOfMacID,
            name: source == .rails ? "Display & rest of Mac" : "Rest of system",
            watts: restOfMacWatts
        ))
        return rows
    }

    /// Activity stays idle: the grade is for apps, and on its scale a lit
    /// display alone would read "Very high" and top an activity sort.
    private static func bucket(id: String, name: String, watts: Double) -> EntityTelemetry {
        EntityTelemetry(
            entityID: id,
            displayName: name,
            kind: .system,
            project: nil,
            processIDs: [],
            processCount: 0,
            cpuPercent: 0,
            cpuSeconds: 0,
            pCoreCPUSeconds: 0,
            residentBytes: 0,
            diskReadBytes: 0,
            diskWrittenBytes: 0,
            wakeups: 0,
            energyJoules: 0,
            powerWatts: watts,
            activityLevel: .idle,
            confidence: .high,
            groupedAutomatically: false
        )
    }
}
