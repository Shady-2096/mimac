import AppKit
import CoreGraphics
import Foundation
import IOKit
import IOKit.ps
import CShim
import MimacCore
import MimacIdentity

private struct ProcessKey: Hashable {
    let pid: Int32
    let startTime: UInt64
}

private struct Counters {
    let cpuMach: UInt64
    let pCoreMach: UInt64
    let energyNJ: UInt64
    let diskRead: UInt64
    let diskWritten: UInt64
    let wakeups: UInt64
}

private struct RawProcess {
    let key: ProcessKey
    let name: String
    let path: String?
    let parentPID: Int32
    let usage: cshim_rusage
}

struct BatteryReading {
    let watts: Double
    let percent: Int
    let onBattery: Bool
    let estimatedMinutesRemaining: Int?
    let fullChargeCapacityWh: Double?
    let remainingCapacityWh: Double?
    let voltage: Double
    let temperatureCelsius: Double?
    /// `PowerTelemetryData.SystemLoad`: whole-machine draw as the power
    /// controller sees it. Refreshes slowly (tens of seconds), so it is only
    /// the fallback when the SMC rail is unreadable.
    let systemLoadWatts: Double?
}

private struct CachedPath {
    let comm: String
    let path: String?
}

final class SystemSampler {
    private var previous: [ProcessKey: Counters] = [:]
    private var pathCache: [ProcessKey: CachedPath] = [:]
    private var previousAbsoluteTime: UInt64?
    private var previousHostCPU: [UInt64]?
    private var drawWindow: [(timestamp: Date, watts: Double)] = []
    private let timebase: mach_timebase_info_data_t
    private let coreCount = max(1, ProcessInfo.processInfo.processorCount)
    private let identityResolver = IdentityResolver()
    private let thermalSensors = ThermalSensors()
    private let smc = SMCReader()
    private let gpuClients = GPUClientSampler()
    private let powerRails = PowerRails()

    init() {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        timebase = info
    }

    func listIdentityRules() -> [IdentityRule] {
        identityResolver.listRules()
    }

    func saveIdentityRule(_ rule: IdentityRule) throws -> IdentityRule {
        try identityResolver.saveRule(rule)
    }

    func deleteIdentityRule(id: String) throws -> Bool {
        try identityResolver.deleteRule(id: id)
    }

    func sample(sequence: UInt64, mode: SamplingMode, idleSeconds: Double) -> CollectorTelemetry {
        let now = Date()
        // Awake time, not wall time. mach_absolute_time stops while the Mac sleeps,
        // so the first sample after a sleep (or after one of the ~15-minute
        // maintenance dark wakes) no longer claims the whole gap as its interval.
        // That gap used to inflate "active" time and weight averages by time the
        // machine was asleep. Wall-clock gaps are still recorded as sleep events
        // by the history store, from the timestamps.
        let absoluteNow = mach_absolute_time()
        let interval = previousAbsoluteTime.map { max(0.001, machSeconds(delta(absoluteNow, $0))) } ?? 1
        previousAbsoluteTime = absoluteNow
        var errors: [String] = []
        let (raw, totalPIDs) = readProcesses(errors: &errors)
        let gpuByPID = gpuClients.sample(intervalSeconds: interval)
        if gpuByPID == nil { errors.append("AGXDeviceUserClient unavailable; per-process GPU not reported") }
        let hostCPU = readHostCPU()
        let rails = powerRails.drain()
        // The mode chosen for this sample sets the length of the next window.
        powerRails.setPeriod(mode == .visible || mode == .active ? 1 : 3)
        var current: [ProcessKey: Counters] = [:]
        var processes: [ProcessTelemetry] = []
        var totalCPUDelta = 0.0
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier

        for process in raw {
            let usage = process.usage
            let counters = Counters(
                cpuMach: usage.user_time_mach &+ usage.system_time_mach,
                pCoreMach: usage.user_ptime_mach &+ usage.system_ptime_mach,
                energyNJ: usage.energy_nj > 0 ? usage.energy_nj : usage.billed_energy,
                diskRead: usage.diskio_bytesread,
                diskWritten: usage.diskio_byteswritten,
                wakeups: usage.pkg_idle_wkups &+ usage.interrupt_wkups
            )
            current[process.key] = counters
            guard let old = previous[process.key] else { continue }

            let cpuDelta = delta(counters.cpuMach, old.cpuMach)
            let cpuSeconds = machSeconds(cpuDelta)
            totalCPUDelta += cpuSeconds
            let pCoreSeconds = machSeconds(delta(counters.pCoreMach, old.pCoreMach))
            let energyJoules = Double(delta(counters.energyNJ, old.energyNJ)) / 1e9
            processes.append(ProcessTelemetry(
                pid: process.key.pid,
                startTime: process.key.startTime,
                name: process.name,
                path: process.path,
                parentPID: process.parentPID,
                cpuPercent: cpuSeconds / interval * 100,
                cpuSeconds: cpuSeconds,
                pCoreCPUSeconds: pCoreSeconds,
                residentBytes: usage.phys_footprint,
                diskReadBytes: delta(counters.diskRead, old.diskRead),
                diskWrittenBytes: delta(counters.diskWritten, old.diskWritten),
                wakeups: delta(counters.wakeups, old.wakeups),
                energyJoules: energyJoules,
                gpuPercent: gpuByPID.map { $0[process.key.pid] ?? 0 },
                isForeground: process.key.pid == frontmostPID
            ))
        }

        previous = current

        // Split the rails before resolving identities, so the GPU share is
        // inside each process's energy and therefore inside every entity,
        // workload and history row built from it.
        let split = rails?.rails.map { rails in
            PowerAttribution.split(
                rails: rails,
                intervalSeconds: interval,
                readableCPUJoules: processes.reduce(0) { $0 + $1.energyJoules },
                gpuPercentByPID: gpuByPID ?? [:],
                readablePIDs: Set(processes.map(\.pid))
            )
        }
        if let split {
            processes = processes.map { process in
                let gpuJoules = split.gpuJoulesByPID[process.pid] ?? 0
                return ProcessTelemetry(
                    pid: process.pid,
                    startTime: process.startTime,
                    name: process.name,
                    path: process.path,
                    parentPID: process.parentPID,
                    cpuPercent: process.cpuPercent,
                    cpuSeconds: process.cpuSeconds,
                    pCoreCPUSeconds: process.pCoreCPUSeconds,
                    residentBytes: process.residentBytes,
                    diskReadBytes: process.diskReadBytes,
                    diskWrittenBytes: process.diskWrittenBytes,
                    wakeups: process.wakeups,
                    energyJoules: process.energyJoules * split.readableCPUScale + gpuJoules,
                    gpuPercent: process.gpuPercent,
                    gpuEnergyJoules: gpuJoules,
                    isForeground: process.isForeground
                )
            }
        } else if rails?.total != nil {
            errors.append("chip power rails unavailable; power beyond CPU counters is not broken down")
        }
        processes.sort {
            if $0.energyJoules != $1.energyJoules { return $0.energyJoules > $1.energyJoules }
            return $0.cpuPercent > $1.cpuPercent
        }

        let resolution = identityResolver.resolve(processes: processes, sampleIntervalSeconds: interval)

        let selfUsage = processes.first { $0.pid == getpid() }
        let battery = readBattery()
        let brightness = readDisplayBrightness()
        let screenOn = CGDisplayIsActive(CGMainDisplayID()) != 0 && CGDisplayIsAsleep(CGMainDisplayID()) == 0
        if battery == nil { errors.append("AppleSmartBattery unavailable") }
        let processDerivedCPU = totalCPUDelta / interval / Double(coreCount) * 100
        let diskReadBytesPerSecond = Double(processes.reduce(UInt64(0)) { $0 &+ $1.diskReadBytes }) / interval
        let diskWrittenBytesPerSecond = Double(processes.reduce(UInt64(0)) { $0 &+ $1.diskWrittenBytes }) / interval
        let hostCPUPercent = hostCPU.flatMap { current -> Double? in
            defer { previousHostCPU = current }
            guard let old = previousHostCPU, old.count == current.count else { return nil }
            let deltas = zip(current, old).map { delta($0.0, $0.1) }
            let total = deltas.reduce(0, +)
            guard total > 0, deltas.count >= 4 else { return nil }
            return Double(total - deltas[3]) / Double(total) * 100
        }
        if hostCPU == nil { errors.append("host_processor_info unavailable; CPU total derived from readable processes") }
        let memory = MemoryProbe.read()
        if memory == nil { errors.append("host_statistics64 unavailable; memory usage not reported") }
        let temperature = thermalSensors.read(now: now, batteryCelsius: battery?.temperatureCelsius)
        if temperature == nil { errors.append("no readable temperature sensors") }
        var entities = resolution.entities
        if let hostCPUPercent, let unreadable = unreadableProcessesEntity(
            hostCPUPercent: hostCPUPercent,
            readable: processes,
            readablePIDs: Set(processes.map(\.pid)),
            unreadableCount: max(0, totalPIDs - raw.count),
            gpuByPID: gpuByPID,
            split: split,
            interval: interval
        ) {
            entities.append(unreadable)
        }
        let systemPowerWatts = rails?.total ?? readSystemPowerWatts(battery: battery)
        let breakdown = split?.breakdown ?? systemPowerWatts.map {
            PowerAttribution.totalOnly(totalWatts: $0, entityWatts: entities.reduce(0) { $0 + $1.powerWatts })
        }
        return CollectorTelemetry(
            schemaVersion: 6,
            sequence: sequence,
            timestamp: now,
            sampleIntervalSeconds: interval,
            samplingMode: mode,
            userIdleSeconds: idleSeconds,
            onBattery: battery?.onBattery ?? false,
            batteryWatts: battery.map { abs($0.watts) },
            systemPowerWatts: systemPowerWatts,
            powerBreakdown: breakdown,
            batteryPercent: battery?.percent,
            batteryFullChargeCapacityWh: battery?.fullChargeCapacityWh,
            batteryVoltage: battery?.voltage,
            displayBrightness: brightness,
            screenOn: screenOn,
            systemCPUPercent: hostCPUPercent ?? processDerivedCPU,
            systemGPUPercent: readSystemGPUPercent(),
            memoryPressure: readMemoryPressure(),
            memory: memory,
            diskReadBytesPerSecond: diskReadBytesPerSecond,
            diskWrittenBytesPerSecond: diskWrittenBytesPerSecond,
            networkBytesPerSecond: nil,
            thermalState: readThermalState(),
            temperature: temperature,
            estimatedBatteryMinutesRemaining: smoothedMinutesRemaining(battery: battery, now: now),
            collectorCPUPercent: selfUsage?.cpuPercent ?? 0,
            collectorResidentBytes: selfUsage?.residentBytes ?? 0,
            processesObserved: raw.count,
            processes: resolution.processes,
            entities: entities,
            workloads: resolution.workloads,
            errors: errors + resolution.errors
        )
    }

    /// Remaining Wh divided by the time-weighted average draw of the last ten
    /// minutes. The gas gauge's own TimeRemaining extrapolates from this second's
    /// amperage, so it swings wildly with every CPU spike; a rolling window gives
    /// a figure that only moves when real behavior changes. Falls back to the
    /// gauge estimate until the window has ninety seconds of data.
    private func smoothedMinutesRemaining(battery: BatteryReading?, now: Date) -> Int? {
        guard let battery, battery.onBattery else {
            drawWindow.removeAll()
            return battery?.estimatedMinutesRemaining
        }
        let watts = abs(battery.watts)
        if watts > 0.05 { drawWindow.append((now, watts)) }
        drawWindow.removeAll { now.timeIntervalSince($0.timestamp) > 600 }

        guard let remaining = battery.remainingCapacityWh, remaining > 0 else {
            return battery.estimatedMinutesRemaining
        }
        var joules = 0.0
        var seconds = 0.0
        for pair in zip(drawWindow, drawWindow.dropFirst()) {
            let dt = pair.1.timestamp.timeIntervalSince(pair.0.timestamp)
            guard dt > 0, dt < 120 else { continue }
            joules += (pair.0.watts + pair.1.watts) / 2 * dt
            seconds += dt
        }
        guard seconds >= 90, joules > 0 else { return battery.estimatedMinutesRemaining }
        let averageWatts = joules / seconds
        let minutes = Int((remaining / averageWatts * 60).rounded())
        return min(minutes, 24 * 60)
    }

    /// Whole-machine draw. The gas gauge's V×I is only the battery's share of
    /// the load: on the adapter at a charge hold it reads 0 W while the machine
    /// pulls 10–20 W, and while charging it reports charge power instead. The
    /// SMC `PSTR` rail measures the system total at ~1 Hz in both states (within
    /// ~2% of the gauge on battery, per FEASIBILITY.md item 11).
    private func readSystemPowerWatts(battery: BatteryReading?) -> Double? {
        if let watts = smc?.value("PSTR"), watts.isFinite, watts > 0, watts < 500 {
            return watts
        }
        if let load = battery?.systemLoadWatts {
            return load
        }
        guard let battery, battery.onBattery else { return nil }
        return abs(battery.watts)
    }

    /// The CPU no readable process accounts for: host scheduler time (which sees
    /// every process and the kernel) minus the sum over readable processes.
    /// Without a privileged helper, root and other-user processes such as
    /// WindowServer, kernel_task and coreaudiod refuse `proc_pid_rusage`, and
    /// their CPU used to vanish from the table. GPU for them is readable from
    /// the driver and is attached here too. Energy, memory and disk stay unknown.
    private func unreadableProcessesEntity(
        hostCPUPercent: Double,
        readable: [ProcessTelemetry],
        readablePIDs: Set<Int32>,
        unreadableCount: Int,
        gpuByPID: [Int32: Double]?,
        split: PowerAttribution.Split?,
        interval: Double
    ) -> EntityTelemetry? {
        // Host CPU is a share of all cores; process CPU is per-core (100 = one core).
        let readableCPU = readable.reduce(0) { $0 + $1.cpuPercent }
        let residualCPU = max(0, hostCPUPercent * Double(coreCount) - readableCPU)
        let gpu = gpuByPID.map { shares in
            shares.reduce(0) { readablePIDs.contains($1.key) ? $0 : $0 + $1.value }
        }
        guard unreadableCount > 0 || residualCPU > 0 else { return nil }
        // With the rails, its power is measured as a remainder: the CPU rail
        // minus every readable counter, plus its GPU-time share of the GPU rail.
        let gpuJoules = split?.unreadableGPUJoules
        let energy = split.map { $0.unreadableCPUJoules + $0.unreadableGPUJoules } ?? 0
        let activity = IdentityResolver.activityLevel(
            powerWatts: energy / interval,
            cpuPercent: residualCPU,
            gpuPercent: gpu ?? 0,
            diskBytesPerSecond: 0,
            wakeupsPerSecond: 0
        )
        return EntityTelemetry(
            entityID: SyntheticEntity.unreadableProcessesID,
            displayName: "System processes",
            kind: .system,
            project: nil,
            processIDs: [],
            processCount: unreadableCount,
            cpuPercent: residualCPU,
            cpuSeconds: residualCPU / 100 * interval,
            pCoreCPUSeconds: 0,
            residentBytes: 0,
            diskReadBytes: 0,
            diskWrittenBytes: 0,
            wakeups: 0,
            energyJoules: energy,
            powerWatts: energy / interval,
            gpuPercent: gpu,
            gpuEnergyJoules: gpuJoules,
            activityLevel: activity.level,
            activityCause: activity.cause,
            confidence: .medium,
            groupedAutomatically: false
        )
    }

    static func userIdleSeconds() -> Double {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        guard service != 0 else { return 0 }
        defer { IOObjectRelease(service) }
        guard let value = IORegistryEntryCreateCFProperty(service, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber else {
            return 0
        }
        return value.doubleValue / 1e9
    }

    static func isOnBattery() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeRetainedValue() else { return false }
        return (type as String) == (kIOPSBatteryPowerValue as String)
    }

    /// Readable processes, plus how many pids exist in total (readable or not).
    private func readProcesses(errors: inout [String]) -> ([RawProcess], Int) {
        let required = proc_listallpids(nil, 0)
        guard required > 0 else {
            errors.append("proc_listallpids size query failed")
            return ([], 0)
        }
        var pids = [Int32](repeating: 0, count: Int(required) * 2)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        guard count > 0 else {
            errors.append("proc_listallpids read failed")
            return ([], 0)
        }

        var livePaths: [ProcessKey: CachedPath] = [:]
        let readable: [RawProcess] = pids.prefix(Int(count)).compactMap { pid in
            guard pid > 0 else { return nil }
            var usage = cshim_rusage()
            guard cshim_get_rusage(pid, &usage) == 0 else { return nil }
            let info = ProcAPI.bsdInfo(for: pid)
            let key = ProcessKey(pid: pid, startTime: usage.proc_start_abstime)
            let comm = info.map(ProcAPI.name(from:)) ?? ""
            // A process's executable is fixed for its lifetime except across exec(),
            // which keeps the pid and start time but renames it, so the kernel name
            // is the cache check. Saves a proc_pidpath per process per sample.
            let path: String?
            if let cached = pathCache[key], cached.comm == comm {
                path = cached.path
            } else {
                path = ProcAPI.path(for: pid)
            }
            livePaths[key] = CachedPath(comm: comm, path: path)
            let name = comm.isEmpty ? (path.map { ($0 as NSString).lastPathComponent } ?? "pid \(pid)") : comm
            return RawProcess(
                key: key,
                name: name,
                path: path,
                parentPID: Int32(info?.pbi_ppid ?? 0),
                usage: usage
            )
        }
        pathCache = livePaths
        return (readable, Int(count))
    }

    private func readBattery() -> BatteryReading? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var propertiesRef: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &propertiesRef, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let properties = propertiesRef?.takeRetainedValue() as? [String: Any],
              let voltage = (properties["Voltage"] as? NSNumber)?.doubleValue else { return nil }
        var amperage = ((properties["InstantAmperage"] ?? properties["Amperage"]) as? NSNumber)?.doubleValue ?? 0
        if amperage > 1e9 { amperage -= 18_446_744_073_709_551_616.0 }
        // macOS 27 dropped the top-level AppleRaw* capacity keys and DesignVoltage;
        // the same mAh figures now live only inside the BatteryData dictionary.
        // Without this fallback every capacity reads 0, so battery percentages
        // and time remaining silently vanish.
        let batteryData = properties["BatteryData"] as? [String: Any] ?? [:]
        func number(_ key: String, in dictionaries: [[String: Any]]) -> Double? {
            for dictionary in dictionaries {
                if let value = (dictionary[key] as? NSNumber)?.doubleValue, value > 0 { return value }
            }
            return nil
        }
        let rawCurrent = number("AppleRawCurrentCapacity", in: [properties])
            ?? number("RemainingCapacity", in: [batteryData]) ?? 0
        let rawMax = number("AppleRawMaxCapacity", in: [properties])
            ?? number("FullChargeCapacity", in: [batteryData])
            ?? number("NominalChargeCapacity", in: [properties, batteryData]) ?? 0
        let nominalVoltage = number("DesignVoltage", in: [properties, batteryData]) ?? voltage
        let displayedCapacity = (properties["CurrentCapacity"] as? NSNumber)?.doubleValue
        // 65535 is the gauge's "not applicable" sentinel; try each estimate in turn.
        let estimatedMinutes = ["TimeRemaining", "AvgTimeToEmpty"]
            .compactMap { (properties[$0] as? NSNumber)?.intValue }
            .first { $0 > 0 && $0 < 24 * 60 }
        let telemetry = properties["PowerTelemetryData"] as? [String: Any]
        let systemLoadWatts = (telemetry?["SystemLoad"] as? NSNumber).map { $0.doubleValue / 1000 }
            .flatMap { $0 > 0 && $0 < 500 ? $0 : nil }
        let percent = displayedCapacity.map { Int($0.rounded()) }
            ?? (rawMax > 0 ? Int((rawCurrent / rawMax * 100).rounded()) : 0)
        return BatteryReading(
            watts: voltage / 1000 * amperage / 1000,
            percent: percent,
            onBattery: !((properties["ExternalConnected"] as? Bool) ?? false),
            estimatedMinutesRemaining: estimatedMinutes,
            fullChargeCapacityWh: rawMax > 0 ? rawMax / 1000 * nominalVoltage / 1000 : nil,
            remainingCapacityWh: rawCurrent > 0 ? rawCurrent / 1000 * nominalVoltage / 1000 : nil,
            voltage: voltage / 1000,
            temperatureCelsius: ThermalSensors.batteryCelsius(from: properties),
            systemLoadWatts: systemLoadWatts
        )
    }

    private func readDisplayBrightness() -> Double? {
        typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
        guard let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY) else { return nil }
        defer { dlclose(handle) }
        guard let symbol = dlsym(handle, "DisplayServicesGetBrightness") else { return nil }
        let function = unsafeBitCast(symbol, to: GetBrightness.self)
        var value: Float = 0
        guard function(CGMainDisplayID(), &value) == 0 else { return nil }
        return min(1, max(0, Double(value)))
    }

    private func readSystemGPUPercent() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IOAccelerator"),
            &iterator
        ) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            defer {
                IOObjectRelease(entry)
                entry = IOIteratorNext(iterator)
            }
            var propertiesRef: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(entry, &propertiesRef, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let properties = propertiesRef?.takeRetainedValue() as? [String: Any],
                  let statistics = properties["PerformanceStatistics"] as? [String: Any] else { continue }
            for key in ["Device Utilization %", "GPU Activity(%)", "Device Utilization"] {
                if let value = (statistics[key] as? NSNumber)?.doubleValue {
                    return min(100, max(0, value))
                }
            }
        }
        return nil
    }

    private func readMemoryPressure() -> MemoryPressureLevel {
        var raw: Int32 = 0
        var length = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &raw, &length, nil, 0) == 0 else {
            return .unknown
        }
        switch raw {
        case 1: return .normal
        case 2: return .warning
        case 4: return .critical
        default: return .unknown
        }
    }

    private func readThermalState() -> ThermalLevel {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .unknown
        }
    }

    private func machSeconds(_ ticks: UInt64) -> Double {
        Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1e9
    }

    private func delta(_ new: UInt64, _ old: UInt64) -> UInt64 {
        new >= old ? new - old : 0
    }

    private func readHostCPU() -> [UInt64]? {
        // Aggregate per-core user/system/idle/nice scheduler ticks. Unlike
        // summing process rusage, this includes kernel and other-user work.
        var processorCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &processorCount,
            &info,
            &infoCount
        )
        guard result == KERN_SUCCESS, let info else { return nil }
        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(UInt(bitPattern: info)),
                vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.size)
            )
        }
        let statesPerCore = Int(CPU_STATE_MAX)
        guard statesPerCore >= 4, Int(infoCount) >= Int(processorCount) * statesPerCore else { return nil }
        var totals = [UInt64](repeating: 0, count: statesPerCore)
        for cpu in 0..<Int(processorCount) {
            for state in 0..<statesPerCore {
                totals[state] += UInt64(max(0, info[cpu * statesPerCore + state]))
            }
        }
        // Normalize to user, nice, system, idle so index 3 remains idle.
        return [
            totals[Int(CPU_STATE_USER)],
            totals[Int(CPU_STATE_NICE)],
            totals[Int(CPU_STATE_SYSTEM)],
            totals[Int(CPU_STATE_IDLE)],
        ]
    }
}
