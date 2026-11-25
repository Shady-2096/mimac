import Foundation

public enum AttributionConfidence: String, Codable, CaseIterable, Sendable {
    case high
    case medium
    case low
}

public enum AttributionCategory: String, Codable, CaseIterable, Sendable {
    case entity
    case display
    case system
    case radios
    case unattributed
}

public struct BatteryHistoryRequest: Codable, Sendable {
    public let range: HistoryRange

    public init(range: HistoryRange) {
        self.range = range
    }
}

public struct BatteryAttributionRow: Codable, Identifiable, Sendable {
    public let id: String
    public let displayName: String
    public let category: AttributionCategory
    public let kind: EntityKind?
    public let measuredJoules: Double
    public let heuristicJoules: Double
    public let batteryPercent: Double
    public let shareOfDrain: Double
    public let foregroundJoules: Double
    public let backgroundJoules: Double
    public let activeDurationSeconds: Double
    public let averageWatts: Double
    public let peakWatts: Double
    public let confidence: AttributionConfidence
    public let dominantCause: String

    public init(id: String, displayName: String, category: AttributionCategory, kind: EntityKind?, measuredJoules: Double, heuristicJoules: Double, batteryPercent: Double, shareOfDrain: Double, foregroundJoules: Double, backgroundJoules: Double, activeDurationSeconds: Double, averageWatts: Double, peakWatts: Double, confidence: AttributionConfidence, dominantCause: String) {
        self.id = id
        self.displayName = displayName
        self.category = category
        self.kind = kind
        self.measuredJoules = measuredJoules
        self.heuristicJoules = heuristicJoules
        self.batteryPercent = batteryPercent
        self.shareOfDrain = shareOfDrain
        self.foregroundJoules = foregroundJoules
        self.backgroundJoules = backgroundJoules
        self.activeDurationSeconds = activeDurationSeconds
        self.averageWatts = averageWatts
        self.peakWatts = peakWatts
        self.confidence = confidence
        self.dominantCause = dominantCause
    }

    public var totalJoules: Double { measuredJoules + heuristicJoules }
}

public struct BatteryDrainPoint: Codable, Identifiable, Sendable {
    public var id: Date { timestamp }
    public let timestamp: Date
    public let durationSeconds: Double
    public let drainWatts: Double?
    public let drainJoules: Double?
    public let onBattery: Bool
    public let excludedReason: String?

    public init(timestamp: Date, durationSeconds: Double, drainWatts: Double?, drainJoules: Double? = nil, onBattery: Bool, excludedReason: String?) {
        self.timestamp = timestamp
        self.durationSeconds = durationSeconds
        self.drainWatts = drainWatts
        self.drainJoules = drainJoules
        self.onBattery = onBattery
        self.excludedReason = excludedReason
    }
}

public struct BatteryHistoryReport: Codable, Sendable {
    public let range: HistoryRange
    public let resolution: HistoryResolution
    public let attributedDurationSeconds: Double
    public let excludedDurationSeconds: Double
    public let totalDrainJoules: Double
    public let totalBatteryPercent: Double
    public let reconciliationErrorPercent: Double
    public let rows: [BatteryAttributionRow]
    public let timeline: [BatteryDrainPoint]

    public init(range: HistoryRange, resolution: HistoryResolution = .minute, attributedDurationSeconds: Double, excludedDurationSeconds: Double, totalDrainJoules: Double, totalBatteryPercent: Double, reconciliationErrorPercent: Double, rows: [BatteryAttributionRow], timeline: [BatteryDrainPoint]) {
        self.range = range
        self.resolution = resolution
        self.attributedDurationSeconds = attributedDurationSeconds
        self.excludedDurationSeconds = excludedDurationSeconds
        self.totalDrainJoules = totalDrainJoules
        self.totalBatteryPercent = totalBatteryPercent
        self.reconciliationErrorPercent = reconciliationErrorPercent
        self.rows = rows
        self.timeline = timeline
    }
}
