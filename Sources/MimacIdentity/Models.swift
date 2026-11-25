import Foundation

public enum SamplingMode: String, Codable, Sendable {
    case visible
    case active
    case idleOnPower
    case idleOnBattery
}

public enum EntityKind: String, Codable, CaseIterable, Sendable {
    case app
    case devServer
    case agent
    case helper
    case system
    case unknown
}

public enum IdentityConfidence: String, Codable, Sendable {
    case high
    case medium
    case low
}

public enum ActivityLevel: String, Codable, CaseIterable, Sendable {
    case idle
    case low
    case medium
    case high
    case veryHigh
    case abnormal
}

public enum MemoryPressureLevel: String, Codable, Sendable {
    case normal
    case warning
    case critical
    case unknown
}

public enum ThermalLevel: String, Codable, Sendable {
    case nominal
    case fair
    case serious
    case critical
    case unknown
}

/// What the on-die and enclosure sensors read, in degrees Celsius. Every field
/// is optional: sensor naming is model-specific, and a Mac that publishes no
/// recognisable sensor for a part reports nothing for it rather than a zero.
public struct TemperatureReading: Codable, Sendable {
    /// Hottest CPU cluster sensor — performance and efficiency cores together.
    public let cpuCelsius: Double?
    /// Hottest GPU cluster sensor.
    public let gpuCelsius: Double?
    /// Battery pack temperature, read from the gas gauge rather than the SMC.
    public let batteryCelsius: Double?
    /// Enclosure (skin) sensor — what the machine feels like to touch, which
    /// runs far cooler than the die.
    public let enclosureCelsius: Double?
    /// Number of sensors behind this reading, for the diagnostics view.
    public let sensorCount: Int

    public init(
        cpuCelsius: Double? = nil,
        gpuCelsius: Double? = nil,
        batteryCelsius: Double? = nil,
        enclosureCelsius: Double? = nil,
        sensorCount: Int = 0
    ) {
        self.cpuCelsius = cpuCelsius
        self.gpuCelsius = gpuCelsius
        self.batteryCelsius = batteryCelsius
        self.enclosureCelsius = enclosureCelsius
        self.sensorCount = sensorCount
    }

    /// The number worth showing when there is room for exactly one: whichever
    /// of the two silicon sensors is currently driving the heat.
    public var hottestSiliconCelsius: Double? {
        switch (cpuCelsius, gpuCelsius) {
        case let (cpu?, gpu?): return max(cpu, gpu)
        case let (cpu?, nil): return cpu
        case let (nil, gpu?): return gpu
        case (nil, nil): return nil
        }
    }

    /// Which part is driving `hottestSiliconCelsius`.
    public var hottestSiliconSource: String? {
        switch (cpuCelsius, gpuCelsius) {
        case let (cpu?, gpu?): return gpu > cpu ? "GPU" : "CPU"
        case (_?, nil): return "CPU"
        case (nil, _?): return "GPU"
        case (nil, nil): return nil
        }
    }

    public var isEmpty: Bool {
        cpuCelsius == nil && gpuCelsius == nil && batteryCelsius == nil && enclosureCelsius == nil
    }
}

/// Physical memory accounting, split the way macOS itself splits it. `usedBytes`
/// is app + wired + compressed, which is what Activity Monitor calls "Memory
/// Used"; file cache is excluded because the kernel gives it back on demand.
public struct MemoryReading: Codable, Sendable {
    public let totalBytes: UInt64
    public let appBytes: UInt64
    public let wiredBytes: UInt64
    public let compressedBytes: UInt64
    public let cachedFilesBytes: UInt64
    public let swapUsedBytes: UInt64

    public init(
        totalBytes: UInt64,
        appBytes: UInt64,
        wiredBytes: UInt64,
        compressedBytes: UInt64,
        cachedFilesBytes: UInt64,
        swapUsedBytes: UInt64
    ) {
        self.totalBytes = totalBytes
        self.appBytes = appBytes
        self.wiredBytes = wiredBytes
        self.compressedBytes = compressedBytes
        self.cachedFilesBytes = cachedFilesBytes
        self.swapUsedBytes = swapUsedBytes
    }

    public var usedBytes: UInt64 { appBytes &+ wiredBytes &+ compressedBytes }

    public var usedFraction: Double {
        totalBytes > 0 ? min(1, Double(usedBytes) / Double(totalBytes)) : 0
    }
}

public struct ResolvedIdentity: Codable, Equatable, Sendable {
    public let entityID: String
    public let displayName: String
    public let kind: EntityKind
    public let project: String?
    public let projectRoot: String?
    public let confidence: IdentityConfidence
    public let groupedAutomatically: Bool
    public let matchSource: String
    public let bundleIdentifier: String?
    public let iconPath: String?
    public let iconName: String?
    public let teamIdentifier: String?
    public let signingIdentifier: String?

    public init(
        entityID: String,
        displayName: String,
        kind: EntityKind,
        project: String? = nil,
        projectRoot: String? = nil,
        confidence: IdentityConfidence,
        groupedAutomatically: Bool = false,
        matchSource: String,
        bundleIdentifier: String? = nil,
        iconPath: String? = nil,
        iconName: String? = nil,
        teamIdentifier: String? = nil,
        signingIdentifier: String? = nil
    ) {
        self.entityID = entityID
        self.displayName = displayName
        self.kind = kind
        self.project = project
        self.projectRoot = projectRoot
        self.confidence = confidence
        self.groupedAutomatically = groupedAutomatically
        self.matchSource = matchSource
        self.bundleIdentifier = bundleIdentifier
        self.iconPath = iconPath
        self.iconName = iconName
        self.teamIdentifier = teamIdentifier
        self.signingIdentifier = signingIdentifier
    }

    public static func unresolved(name: String) -> ResolvedIdentity {
        ResolvedIdentity(
            entityID: "unresolved:\(name.lowercased())",
            displayName: name,
            kind: .unknown,
            confidence: .low,
            matchSource: "unresolved"
        )
    }
}

public struct ProcessTelemetry: Codable, Sendable {
    public let pid: Int32
    public let startTime: UInt64
    public let name: String
    public let path: String?
    public let parentPID: Int32
    public let parentChain: [Int32]
    public let arguments: [String]?
    public let cwd: String?
    public let listeningPorts: [UInt16]
    public let cpuPercent: Double
    public let cpuSeconds: Double
    public let pCoreCPUSeconds: Double
    public let residentBytes: UInt64
    public let diskReadBytes: UInt64
    public let diskWrittenBytes: UInt64
    public let wakeups: UInt64
    /// CPU energy from the kernel counter plus `gpuEnergyJoules`.
    public let energyJoules: Double
    /// Share of GPU time over the sample, from the AGX driver's per-client
    /// counters (the source of Activity Monitor's %GPU). Nil when unreadable.
    public let gpuPercent: Double?
    /// This process's share of the GPU rail by GPU time, already inside
    /// `energyJoules`. A split of a measured rail by a measured share, so it is
    /// shown as estimated. Nil when the rails are unreadable.
    public let gpuEnergyJoules: Double?
    public let isForeground: Bool
    public let identity: ResolvedIdentity

    public init(
        pid: Int32,
        startTime: UInt64 = 0,
        name: String,
        path: String?,
        parentPID: Int32 = 0,
        parentChain: [Int32] = [],
        arguments: [String]? = nil,
        cwd: String? = nil,
        listeningPorts: [UInt16] = [],
        cpuPercent: Double,
        cpuSeconds: Double,
        pCoreCPUSeconds: Double,
        residentBytes: UInt64,
        diskReadBytes: UInt64,
        diskWrittenBytes: UInt64,
        wakeups: UInt64,
        energyJoules: Double,
        gpuPercent: Double? = nil,
        gpuEnergyJoules: Double? = nil,
        isForeground: Bool = false,
        identity: ResolvedIdentity? = nil
    ) {
        self.pid = pid
        self.startTime = startTime
        self.name = name
        self.path = path
        self.parentPID = parentPID
        self.parentChain = parentChain
        self.arguments = arguments
        self.cwd = cwd
        self.listeningPorts = listeningPorts
        self.cpuPercent = cpuPercent
        self.cpuSeconds = cpuSeconds
        self.pCoreCPUSeconds = pCoreCPUSeconds
        self.residentBytes = residentBytes
        self.diskReadBytes = diskReadBytes
        self.diskWrittenBytes = diskWrittenBytes
        self.wakeups = wakeups
        self.energyJoules = energyJoules
        self.gpuPercent = gpuPercent
        self.gpuEnergyJoules = gpuEnergyJoules
        self.isForeground = isForeground
        self.identity = identity ?? .unresolved(name: name)
    }
}

/// Rows the collector synthesizes rather than resolves from a process.
public enum SyntheticEntity {
    /// CPU (and GPU) that belongs to no readable process: root and other-user
    /// processes such as WindowServer and kernel_task, which `proc_pid_rusage`
    /// refuses without privileges, plus processes born or reaped mid-sample.
    /// Total CPU minus every readable process, so it is exact in aggregate.
    /// Its power is the CPU rail minus every readable process's counter, plus
    /// their GPU share; memory and disk stay unknown.
    public static let unreadableProcessesID = "system:unreadable-processes"
    /// Chip power no process accounts for: memory, media engines, fabric, the
    /// chip's power delivery, and GPU power while no client is using the GPU.
    public static let chipID = "power:chip"
    /// Everything outside the chip: display backlight, storage, Wi-Fi and
    /// Bluetooth, audio, and power conversion losses.
    public static let restOfMacID = "power:rest-of-mac"

    /// Rows that stand for hardware, not processes. Built from the snapshot's
    /// `powerBreakdown` by the app, never persisted as entities; averaged
    /// windows build them from the energy `system_samples` keeps (history v6).
    public static func isPowerBucket(_ entityID: String) -> Bool {
        entityID == chipID || entityID == restOfMacID
    }
}

public struct EntityTelemetry: Codable, Sendable {
    public let entityID: String
    public let displayName: String
    public let kind: EntityKind
    public let project: String?
    public let processIDs: [Int32]
    public let processCount: Int
    public let cpuPercent: Double
    public let cpuSeconds: Double
    public let pCoreCPUSeconds: Double
    public let residentBytes: UInt64
    public let diskReadBytes: UInt64
    public let diskWrittenBytes: UInt64
    public let wakeups: UInt64
    public let energyJoules: Double
    public let foreground: Bool
    public let powerWatts: Double
    /// Measured share of GPU time, summed over the entity's processes.
    public let gpuPercent: Double?
    /// The estimated GPU part of `energyJoules`; see `ProcessTelemetry`.
    public let gpuEnergyJoules: Double?
    public let networkBytesPerSecond: Double?
    public let activityLevel: ActivityLevel
    public let activityCause: String?
    public let confidence: IdentityConfidence
    public let groupedAutomatically: Bool

    public init(
        entityID: String,
        displayName: String,
        kind: EntityKind,
        project: String?,
        processIDs: [Int32],
        processCount: Int,
        cpuPercent: Double,
        cpuSeconds: Double,
        pCoreCPUSeconds: Double,
        residentBytes: UInt64,
        diskReadBytes: UInt64,
        diskWrittenBytes: UInt64,
        wakeups: UInt64,
        energyJoules: Double,
        foreground: Bool = false,
        powerWatts: Double = 0,
        gpuPercent: Double? = nil,
        gpuEnergyJoules: Double? = nil,
        networkBytesPerSecond: Double? = nil,
        activityLevel: ActivityLevel = .idle,
        activityCause: String? = nil,
        confidence: IdentityConfidence,
        groupedAutomatically: Bool
    ) {
        self.entityID = entityID
        self.displayName = displayName
        self.kind = kind
        self.project = project
        self.processIDs = processIDs
        self.processCount = processCount
        self.cpuPercent = cpuPercent
        self.cpuSeconds = cpuSeconds
        self.pCoreCPUSeconds = pCoreCPUSeconds
        self.residentBytes = residentBytes
        self.diskReadBytes = diskReadBytes
        self.diskWrittenBytes = diskWrittenBytes
        self.wakeups = wakeups
        self.energyJoules = energyJoules
        self.foreground = foreground
        self.powerWatts = powerWatts
        self.gpuPercent = gpuPercent
        self.gpuEnergyJoules = gpuEnergyJoules
        self.networkBytesPerSecond = networkBytesPerSecond
        self.activityLevel = activityLevel
        self.activityCause = activityCause
        self.confidence = confidence
        self.groupedAutomatically = groupedAutomatically
    }
}

public struct WorkloadTelemetry: Codable, Sendable {
    public let workloadID: String
    public let displayName: String
    public let project: String
    public let projectRoot: String
    public let entityIDs: [String]
    public let processCount: Int
    public let cpuPercent: Double
    public let cpuSeconds: Double
    public let residentBytes: UInt64
    public let diskReadBytes: UInt64
    public let diskWrittenBytes: UInt64
    public let wakeups: UInt64
    public let energyJoules: Double

    public init(
        workloadID: String,
        displayName: String,
        project: String,
        projectRoot: String,
        entityIDs: [String],
        processCount: Int,
        cpuPercent: Double,
        cpuSeconds: Double,
        residentBytes: UInt64,
        diskReadBytes: UInt64,
        diskWrittenBytes: UInt64,
        wakeups: UInt64,
        energyJoules: Double
    ) {
        self.workloadID = workloadID
        self.displayName = displayName
        self.project = project
        self.projectRoot = projectRoot
        self.entityIDs = entityIDs
        self.processCount = processCount
        self.cpuPercent = cpuPercent
        self.cpuSeconds = cpuSeconds
        self.residentBytes = residentBytes
        self.diskReadBytes = diskReadBytes
        self.diskWrittenBytes = diskWrittenBytes
        self.wakeups = wakeups
        self.energyJoules = energyJoules
    }
}

public struct CollectorTelemetry: Codable, Sendable {
    public let schemaVersion: Int
    public let sequence: UInt64
    public let timestamp: Date
    public let sampleIntervalSeconds: Double
    public let samplingMode: SamplingMode
    public let userIdleSeconds: Double
    public let onBattery: Bool
    /// Battery charge (+) or discharge power from the gas gauge. Zero while the
    /// adapter carries the whole load, so it is NOT what the machine draws.
    public let batteryWatts: Double?
    /// What the whole machine draws, from the SMC system-total rail (`PSTR`),
    /// falling back to the gauge's `PowerTelemetryData.SystemLoad`. Valid on
    /// adapter and on battery alike. Nil from collectors older than schema 5.
    /// From schema 6 it is the average over the sample, not one reading.
    public let systemPowerWatts: Double?
    /// Where `systemPowerWatts` went, so entities plus the two hardware rows
    /// add up to it. Nil from collectors older than schema 6.
    public let powerBreakdown: PowerBreakdown?
    public let batteryPercent: Int?
    public let batteryFullChargeCapacityWh: Double?
    public let batteryVoltage: Double?
    public let displayBrightness: Double?
    public let screenOn: Bool
    public let systemCPUPercent: Double
    public let systemGPUPercent: Double?
    public let memoryPressure: MemoryPressureLevel
    public let memory: MemoryReading?
    public let diskReadBytesPerSecond: Double
    public let diskWrittenBytesPerSecond: Double
    public let networkBytesPerSecond: Double?
    public let thermalState: ThermalLevel
    public let temperature: TemperatureReading?
    public let estimatedBatteryMinutesRemaining: Int?
    public let collectorCPUPercent: Double
    public let collectorResidentBytes: UInt64
    public let processesObserved: Int
    public let processes: [ProcessTelemetry]
    public let entities: [EntityTelemetry]
    public let workloads: [WorkloadTelemetry]
    public let errors: [String]

    public init(
        schemaVersion: Int = 6,
        sequence: UInt64,
        timestamp: Date,
        sampleIntervalSeconds: Double,
        samplingMode: SamplingMode,
        userIdleSeconds: Double,
        onBattery: Bool,
        batteryWatts: Double?,
        systemPowerWatts: Double? = nil,
        powerBreakdown: PowerBreakdown? = nil,
        batteryPercent: Int?,
        batteryFullChargeCapacityWh: Double? = nil,
        batteryVoltage: Double? = nil,
        displayBrightness: Double? = nil,
        screenOn: Bool = true,
        systemCPUPercent: Double,
        systemGPUPercent: Double? = nil,
        memoryPressure: MemoryPressureLevel = .unknown,
        memory: MemoryReading? = nil,
        diskReadBytesPerSecond: Double = 0,
        diskWrittenBytesPerSecond: Double = 0,
        networkBytesPerSecond: Double? = nil,
        thermalState: ThermalLevel = .unknown,
        temperature: TemperatureReading? = nil,
        estimatedBatteryMinutesRemaining: Int? = nil,
        collectorCPUPercent: Double,
        collectorResidentBytes: UInt64,
        processesObserved: Int,
        processes: [ProcessTelemetry],
        entities: [EntityTelemetry] = [],
        workloads: [WorkloadTelemetry] = [],
        errors: [String]
    ) {
        self.schemaVersion = schemaVersion
        self.sequence = sequence
        self.timestamp = timestamp
        self.sampleIntervalSeconds = sampleIntervalSeconds
        self.samplingMode = samplingMode
        self.userIdleSeconds = userIdleSeconds
        self.onBattery = onBattery
        self.batteryWatts = batteryWatts
        self.systemPowerWatts = systemPowerWatts
        self.powerBreakdown = powerBreakdown
        self.batteryPercent = batteryPercent
        self.batteryFullChargeCapacityWh = batteryFullChargeCapacityWh
        self.batteryVoltage = batteryVoltage
        self.displayBrightness = displayBrightness
        self.screenOn = screenOn
        self.systemCPUPercent = systemCPUPercent
        self.systemGPUPercent = systemGPUPercent
        self.memoryPressure = memoryPressure
        self.memory = memory
        self.diskReadBytesPerSecond = diskReadBytesPerSecond
        self.diskWrittenBytesPerSecond = diskWrittenBytesPerSecond
        self.networkBytesPerSecond = networkBytesPerSecond
        self.thermalState = thermalState
        self.temperature = temperature
        self.estimatedBatteryMinutesRemaining = estimatedBatteryMinutesRemaining
        self.collectorCPUPercent = collectorCPUPercent
        self.collectorResidentBytes = collectorResidentBytes
        self.processesObserved = processesObserved
        self.processes = processes
        self.entities = entities
        self.workloads = workloads
        self.errors = errors
    }
}

public struct CollectorHealth: Codable, Sendable {
    public let status: String
    public let pid: Int32
    public let startedAt: Date
    public let sequence: UInt64
    public let samplingMode: SamplingMode?
    public let lastSampleAt: Date?
    public let lastErrorCount: Int

    public init(status: String, pid: Int32, startedAt: Date, sequence: UInt64, samplingMode: SamplingMode?, lastSampleAt: Date?, lastErrorCount: Int) {
        self.status = status
        self.pid = pid
        self.startedAt = startedAt
        self.sequence = sequence
        self.samplingMode = samplingMode
        self.lastSampleAt = lastSampleAt
        self.lastErrorCount = lastErrorCount
    }
}
