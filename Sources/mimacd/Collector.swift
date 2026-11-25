import Foundation
import MimacHistory
import MimacIdentity

final class Collector {
    private let queue = DispatchQueue(label: "com.mimac.collector.sampling", qos: .utility)
    private let sampler = SystemSampler()
    private let historyStore: HistoryStore?
    private var historyError: String?
    private var timer: DispatchSourceTimer?
    private var latest: CollectorTelemetry?
    private var sequence: UInt64 = 0
    /// The latest sample as clients read it, behind its own lock so a reply never
    /// waits for a tick or history maintenance in progress on `queue`. Encoded at
    /// most once per sample, on first request, instead of once per request.
    private let publishedLock = NSLock()
    private var published: CollectorTelemetry?
    private var publishedData: Data?
    private let snapshotEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
    private var visibleClients = Set<UUID>()
    private var recentLoad = 0.0
    let startedAt = Date()

    init() {
        do {
            historyStore = try HistoryStore()
        } catch {
            historyStore = nil
            historyError = error.localizedDescription
        }
    }

    func start() {
        queue.async { [weak self] in self?.schedule(after: 0) }
    }

    func setClientVisible(_ visible: Bool, clientID: UUID) {
        queue.async { [weak self] in
            guard let self else { return }
            let changed: Bool
            if visible {
                changed = visibleClients.insert(clientID).inserted
            } else {
                changed = visibleClients.remove(clientID) != nil
            }
            guard changed else { return }
            timer?.cancel()
            // Re-sample promptly, but never less than a second after the last
            // sample: host CPU ticks are 10 ms, so a 0.1 s interval makes every
            // rate (and the unreadable-processes residual) mostly quantization.
            let sinceLast = latest.map { Date().timeIntervalSince($0.timestamp) } ?? .infinity
            schedule(after: max(0, 1 - sinceLast))
        }
    }

    func removeClient(_ clientID: UUID) {
        setClientVisible(false, clientID: clientID)
    }

    func snapshot() -> CollectorTelemetry? {
        publishedLock.withLock { published }
    }

    /// nil before the first sample; empty when the latest sample is `unlessSequence`.
    func snapshotData(unlessSequence known: UInt64? = nil) throws -> Data? {
        try publishedLock.withLock {
            guard let published else { return nil }
            if let known, known == published.sequence { return Data() }
            if let publishedData { return publishedData }
            let data = try snapshotEncoder.encode(published)
            publishedData = data
            return data
        }
    }

    func health() -> CollectorHealth {
        queue.sync {
            CollectorHealth(
                status: latest == nil ? "starting" : "ok",
                pid: getpid(),
                startedAt: startedAt,
                sequence: sequence,
                samplingMode: latest?.samplingMode,
                lastSampleAt: latest?.timestamp,
                lastErrorCount: latest?.errors.count ?? 0
            )
        }
    }

    func listIdentityRules() -> [IdentityRule] {
        queue.sync { sampler.listIdentityRules() }
    }

    @discardableResult
    func saveIdentityRule(_ rule: IdentityRule) throws -> IdentityRule {
        try queue.sync { try sampler.saveIdentityRule(rule) }
    }

    func deleteIdentityRule(id: String) throws -> Bool {
        try queue.sync { try sampler.deleteIdentityRule(id: id) }
    }

    func historyStorageHealth() throws -> HistoryStorageHealth {
        try queue.sync {
            if let historyError {
                throw NSError(domain: "MimacHistory", code: 1, userInfo: [NSLocalizedDescriptionKey: historyError])
            }
            guard let historyStore else {
                throw NSError(domain: "MimacHistory", code: 2, userInfo: [NSLocalizedDescriptionKey: "history storage is unavailable"])
            }
            return try historyStore.health()
        }
    }

    func historyEntityTimeline(_ request: EntityTimelineRequest) throws -> EntityTimeline {
        try queue.sync {
            guard let historyStore else { throw historyUnavailableError() }
            return try historyStore.entityTimeline(request)
        }
    }

    func historyTopEntities(_ request: TopEntitiesRequest) throws -> [RankedEntityHistory] {
        try queue.sync {
            guard let historyStore else { throw historyUnavailableError() }
            return try historyStore.topEntities(request)
        }
    }

    func historyEntityUsage(_ request: EntityUsageRequest) throws -> [EntityUsageSummary] {
        try queue.sync {
            guard let historyStore else { throw historyUnavailableError() }
            return try historyStore.entityUsage(request)
        }
    }

    func historySystemTimeline(_ range: HistoryRange) throws -> SystemTimeline {
        try queue.sync {
            guard let historyStore else { throw historyUnavailableError() }
            return try historyStore.systemTimeline(range)
        }
    }

    func batteryHistory(_ request: BatteryHistoryRequest) throws -> BatteryHistoryReport {
        try queue.sync {
            guard let historyStore else { throw historyUnavailableError() }
            return try historyStore.batteryHistory(request)
        }
    }

    private func schedule(after delay: TimeInterval) {
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + delay)
        source.setEventHandler { [weak self] in self?.tick() }
        timer = source
        source.resume()
    }

    private func tick() {
        timer?.cancel()
        timer = nil
        let idle = SystemSampler.userIdleSeconds()
        let onBattery = SystemSampler.isOnBattery()
        let mode: SamplingMode
        let nextInterval: TimeInterval
        if !visibleClients.isEmpty {
            mode = .visible
            nextInterval = 2
        } else if idle < 60 || recentLoad >= 10 {
            mode = .active
            nextInterval = 5
        } else if onBattery {
            mode = .idleOnBattery
            nextInterval = 30
        } else {
            mode = .idleOnPower
            nextInterval = 15
        }
        sequence &+= 1
        let sample = sampler.sample(sequence: sequence, mode: mode, idleSeconds: idle)
        do {
            try historyStore?.persist(sample)
            historyError = nil
        } catch {
            historyError = error.localizedDescription
            let line = "mimacd history error: \(error.localizedDescription)\n"
            FileHandle.standardError.write(Data(line.utf8))
        }
        latest = sample
        publishedLock.withLock {
            published = sample
            publishedData = nil
        }
        recentLoad = latest?.systemCPUPercent ?? 0
        log(latest!)
        schedule(after: nextInterval)
    }

    private func historyUnavailableError() -> Error {
        NSError(
            domain: "MimacHistory",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: historyError ?? "history storage is unavailable"]
        )
    }

    private func log(_ sample: CollectorTelemetry) {
        let battery = sample.batteryWatts.map { String(format: "%.2fW", $0) } ?? "n/a"
        let system = sample.systemPowerWatts.map { String(format: "%.2fW", $0) } ?? "n/a"
        let line = String(
            format: "mimacd seq=%llu mode=%@ interval=%.1fs cpu=%.1f%% self=%.2f%% rss=%.1fMB system=%@ battery=%@ processes=%d errors=%d\n",
            sample.sequence,
            sample.samplingMode.rawValue,
            sample.sampleIntervalSeconds,
            sample.systemCPUPercent,
            sample.collectorCPUPercent,
            Double(sample.collectorResidentBytes) / 1_048_576,
            system,
            battery,
            sample.processesObserved,
            sample.errors.count
        )
        FileHandle.standardError.write(Data(line.utf8))
    }
}
