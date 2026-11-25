import Foundation

public enum HistoryResolution: String, Codable, CaseIterable, Sendable {
    case automatic
    case raw
    case minute
    case hour
    case day
}

public enum HistoryMetric: String, Codable, CaseIterable, Sendable {
    case cpuSeconds
    case energyJoules
    case residentBytes
    case diskReadBytes
    case diskWrittenBytes
    case wakeups
}

public struct HistoryRange: Codable, Sendable {
    public let start: Date
    public let end: Date
    public let resolution: HistoryResolution

    public init(start: Date, end: Date, resolution: HistoryResolution = .automatic) {
        self.start = start
        self.end = end
        self.resolution = resolution
    }
}

public struct EntityTimelineRequest: Codable, Sendable {
    public let entityID: String
    public let range: HistoryRange

    public init(entityID: String, range: HistoryRange) {
        self.entityID = entityID
        self.range = range
    }
}

public struct TopEntitiesRequest: Codable, Sendable {
    public let range: HistoryRange
    public let metric: HistoryMetric
    public let limit: Int

    public init(range: HistoryRange, metric: HistoryMetric = .energyJoules, limit: Int = 10) {
        self.range = range
        self.metric = metric
        self.limit = limit
    }
}

public struct EntityHistoryPoint: Codable, Sendable {
    public let timestamp: Date
    public let durationSeconds: Double
    public let cpuSeconds: Double
    public let averageCPUPercent: Double
    public let averageResidentBytes: Double
    public let peakResidentBytes: UInt64
    public let diskReadBytes: UInt64
    public let diskWrittenBytes: UInt64
    public let wakeups: UInt64
    public let energyJoules: Double
    public let averagePowerWatts: Double

    public init(timestamp: Date, durationSeconds: Double, cpuSeconds: Double, averageCPUPercent: Double, averageResidentBytes: Double, peakResidentBytes: UInt64, diskReadBytes: UInt64, diskWrittenBytes: UInt64, wakeups: UInt64, energyJoules: Double, averagePowerWatts: Double) {
        self.timestamp = timestamp
        self.durationSeconds = durationSeconds
        self.cpuSeconds = cpuSeconds
        self.averageCPUPercent = averageCPUPercent
        self.averageResidentBytes = averageResidentBytes
        self.peakResidentBytes = peakResidentBytes
        self.diskReadBytes = diskReadBytes
        self.diskWrittenBytes = diskWrittenBytes
        self.wakeups = wakeups
        self.energyJoules = energyJoules
        self.averagePowerWatts = averagePowerWatts
    }
}

public struct EntityTimeline: Codable, Sendable {
    public let entityID: String
    public let displayName: String?
    public let resolution: HistoryResolution
    public let points: [EntityHistoryPoint]

    public init(entityID: String, displayName: String?, resolution: HistoryResolution, points: [EntityHistoryPoint]) {
        self.entityID = entityID
        self.displayName = displayName
        self.resolution = resolution
        self.points = points
    }
}

public struct RankedEntityHistory: Codable, Sendable {
    public let entityID: String
    public let displayName: String
    public let kind: EntityKind
    public let value: Double
    public let metric: HistoryMetric

    public init(entityID: String, displayName: String, kind: EntityKind, value: Double, metric: HistoryMetric) {
        self.entityID = entityID
        self.displayName = displayName
        self.kind = kind
        self.value = value
        self.metric = metric
    }
}

public struct SystemHistoryPoint: Codable, Sendable {
    public let timestamp: Date
    public let durationSeconds: Double
    public let averageBatteryWatts: Double?
    public let minimumBatteryPercent: Int?
    public let maximumBatteryPercent: Int?
    public let averageCPUPercent: Double
    public let averageGPUPercent: Double?
    public let onBatteryFraction: Double
    public let worstMemoryPressure: MemoryPressureLevel
    public let worstThermalState: ThermalLevel

    public init(timestamp: Date, durationSeconds: Double, averageBatteryWatts: Double?, minimumBatteryPercent: Int?, maximumBatteryPercent: Int?, averageCPUPercent: Double, averageGPUPercent: Double?, onBatteryFraction: Double, worstMemoryPressure: MemoryPressureLevel, worstThermalState: ThermalLevel) {
        self.timestamp = timestamp
        self.durationSeconds = durationSeconds
        self.averageBatteryWatts = averageBatteryWatts
        self.minimumBatteryPercent = minimumBatteryPercent
        self.maximumBatteryPercent = maximumBatteryPercent
        self.averageCPUPercent = averageCPUPercent
        self.averageGPUPercent = averageGPUPercent
        self.onBatteryFraction = onBatteryFraction
        self.worstMemoryPressure = worstMemoryPressure
        self.worstThermalState = worstThermalState
    }
}

public struct SystemTimeline: Codable, Sendable {
    public let resolution: HistoryResolution
    public let points: [SystemHistoryPoint]

    public init(resolution: HistoryResolution, points: [SystemHistoryPoint]) {
        self.resolution = resolution
        self.points = points
    }
}

public struct EntityUsageRequest: Codable, Sendable {
    public let range: HistoryRange
    public let limit: Int

    public init(range: HistoryRange, limit: Int = 100) {
        self.range = range
        self.limit = limit
    }
}

/// Duration-weighted usage of one entity over a window — the stable alternative
/// to instantaneous snapshot rows.
public struct EntityUsageSummary: Codable, Identifiable, Sendable {
    public var id: String { entityID }
    public let entityID: String
    public let displayName: String
    public let kind: EntityKind
    public let project: String?
    public let averageCPUPercent: Double
    public let averageResidentBytes: Double
    public let diskBytesPerSecond: Double
    /// Energy spread over the whole window, not just the entity's active
    /// seconds — a seven-second burst must not outrank an hour of steady load.
    public let averagePowerWatts: Double
    public let energyJoules: Double
    public let activeSeconds: Double
    public let windowSeconds: Double

    public init(entityID: String, displayName: String, kind: EntityKind, project: String?, averageCPUPercent: Double, averageResidentBytes: Double, diskBytesPerSecond: Double, averagePowerWatts: Double, energyJoules: Double, activeSeconds: Double, windowSeconds: Double) {
        self.entityID = entityID
        self.displayName = displayName
        self.kind = kind
        self.project = project
        self.averageCPUPercent = averageCPUPercent
        self.averageResidentBytes = averageResidentBytes
        self.diskBytesPerSecond = diskBytesPerSecond
        self.averagePowerWatts = averagePowerWatts
        self.energyJoules = energyJoules
        self.activeSeconds = activeSeconds
        self.windowSeconds = windowSeconds
    }
}

public struct HistoryStorageHealth: Codable, Sendable {
    public let databasePath: String
    public let databaseBytes: UInt64
    public let rawEntitySamples: Int
    public let rawSystemSamples: Int
    public let minuteRollups: Int
    public let hourRollups: Int
    public let dayRollups: Int
    public let batteryWindows: Int
    public let batteryHourRollups: Int
    public let batteryDayRollups: Int
    public let minuteFillRatePercent24h: Double
    public let eventCount: Int
    public let lastPersistedAt: Date?

    public init(databasePath: String, databaseBytes: UInt64, rawEntitySamples: Int, rawSystemSamples: Int, minuteRollups: Int, hourRollups: Int, dayRollups: Int, batteryWindows: Int = 0, batteryHourRollups: Int = 0, batteryDayRollups: Int = 0, minuteFillRatePercent24h: Double = 0, eventCount: Int, lastPersistedAt: Date?) {
        self.databasePath = databasePath
        self.databaseBytes = databaseBytes
        self.rawEntitySamples = rawEntitySamples
        self.rawSystemSamples = rawSystemSamples
        self.minuteRollups = minuteRollups
        self.hourRollups = hourRollups
        self.dayRollups = dayRollups
        self.batteryWindows = batteryWindows
        self.batteryHourRollups = batteryHourRollups
        self.batteryDayRollups = batteryDayRollups
        self.minuteFillRatePercent24h = minuteFillRatePercent24h
        self.eventCount = eventCount
        self.lastPersistedAt = lastPersistedAt
    }
}
