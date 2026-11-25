import Foundation
import MimacIdentity

enum BatteryHistoryRange: String, CaseIterable, Identifiable {
    case hour
    case day
    case week
    case month

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hour: return "1 H"
        case .day: return "24 H"
        case .week: return "7 D"
        case .month: return "30 D"
        }
    }

    var resolution: HistoryResolution {
        switch self {
        case .hour, .day: return .minute
        case .week, .month: return .day
        }
    }

    func start(before end: Date) -> Date {
        switch self {
        case .hour: return end.addingTimeInterval(-3600)
        case .day: return end.addingTimeInterval(-24 * 3600)
        case .week, .month:
            let days = self == .week ? 6 : 29
            let dayStart = Calendar.current.startOfDay(for: end)
            return Calendar.current.date(byAdding: .day, value: -days, to: dayStart) ?? dayStart
        }
    }
}

@MainActor
final class LiveViewModel: ObservableObject {
    enum ConnectionState: Equatable {
        case connecting
        case live
        case unavailable(String)

        var label: String {
            switch self {
            case .connecting: return "Connecting"
            case .live: return "Live"
            case .unavailable: return "Offline"
            }
        }
    }

    struct WattReading: Identifiable {
        let id: Date
        let watts: Double
        init(date: Date, watts: Double) {
            id = date
            self.watts = watts
        }
    }

    enum UsageWindow: String, CaseIterable {
        case now = "Now"
        case tenMinutes = "10 min"
        case hour = "1 h"

        var minutes: Double? {
            switch self {
            case .now: return nil
            case .tenMinutes: return 10
            case .hour: return 60
            }
        }
    }

    @Published private(set) var snapshot: CollectorTelemetry?
    /// The snapshot's entities plus the hardware rows (memory & chip, display &
    /// rest of Mac), so the Power column adds up to the system draw.
    @Published private(set) var liveEntities: [EntityTelemetry] = []
    @Published private(set) var wattsHistory: [WattReading] = []
    /// Recent power per entity, so every row can carry its own short history.
    /// Activity Monitor keeps no past at all; this is the cheapest place to show
    /// that Mimac does. Held in the UI only — the daemon already persists the
    /// durable version.
    @Published private(set) var entityHistory: [String: [Double]] = [:]
    private static let entityHistoryLength = 32
    @Published var usageWindow: UsageWindow = .now
    @Published private(set) var usageSummaries: [EntityUsageSummary] = []
    @Published private(set) var usageError: String?
    private var usageLoadedAt: Date?
    @Published private(set) var connectionState: ConnectionState = .connecting
    @Published private(set) var isSavingRule = false
    @Published var renameError: String?
    @Published private(set) var batteryReport: BatteryHistoryReport?
    @Published private(set) var batteryDayReport: BatteryHistoryReport?
    @Published private(set) var batteryError: String?
    @Published private(set) var isLoadingBattery = false
    @Published private(set) var isLoadingBatteryDay = false

    private let client = CollectorClient()
    private var pollingTask: Task<Void, Never>?
    private var isLiveVisible = true
    /// False while the window is minimized, covered, on another Space, or the app
    /// is hidden. Nothing is on screen then, so polling stops instead of pulling
    /// and decoding a ~600 KB snapshot nobody sees every 10 seconds.
    private var isWindowOnScreen = true
    private var retryDelaySeconds: Double = 1

    func start() {
        guard pollingTask == nil else { return }
        client.onDisconnect = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.connectionState = .unavailable("Collector connection was interrupted.")
            }
        }
        pollingTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                if isWindowOnScreen || connectionState != .live {
                    await refresh()
                }
                let delay = connectionState == .live ? (isLiveVisible ? 2.0 : 10.0) : retryDelaySeconds
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }

    func setWindowOnScreen(_ onScreen: Bool) {
        let returned = onScreen && !isWindowOnScreen
        isWindowOnScreen = onScreen
        // Don't make a returning user wait out the 10-second hidden-poll sleep.
        if returned { Task { await refresh() } }
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
        Task { try? await client.setVisible(false) }
        client.invalidate()
    }

    func setLiveVisible(_ visible: Bool) {
        let becameVisible = visible && !isLiveVisible
        isLiveVisible = visible
        Task {
            do {
                try await client.setVisible(visible)
                // Switching back to Live from Battery shouldn't wait out the
                // 10-second background poll either.
                if becameVisible { await refresh() }
            } catch {
                if visible { connectionState = .unavailable(error.localizedDescription) }
            }
        }
    }

    func retryNow() {
        client.invalidate()
        retryDelaySeconds = 1
        connectionState = .connecting
        pollingTask?.cancel()
        pollingTask = nil
        start()
    }

    func startDaemon() {
        connectionState = .connecting
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = ["kickstart", "-k", "gui/\(getuid())/\(collectorMachService)"]
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            connectionState = .unavailable("Could not ask launchd to start the collector: \(error.localizedDescription)")
        }
        retryNow()
    }

    /// Each row asked for its processes by scanning every process, so a render
    /// cost rows × processes (~150k comparisons). Indexed once per sample instead.
    private var processesByEntity: [String: [ProcessTelemetry]] = [:]
    private var iconProcessByEntity: [String: ProcessTelemetry] = [:]

    private func indexProcesses(_ sample: CollectorTelemetry) {
        var grouped: [String: [ProcessTelemetry]] = [:]
        for process in sample.processes {
            grouped[process.identity.entityID, default: []].append(process)
        }
        var icons: [String: ProcessTelemetry] = [:]
        for (id, members) in grouped {
            grouped[id] = members.sorted { $0.cpuPercent > $1.cpuPercent }
            icons[id] = members.first { $0.identity.iconPath != nil } ?? members.first
        }
        processesByEntity = grouped
        iconProcessByEntity = icons
    }

    func iconProcess(for entityID: String) -> ProcessTelemetry? {
        iconProcessByEntity[entityID]
    }

    func processes(for entity: EntityTelemetry) -> [ProcessTelemetry] {
        processesByEntity[entity.entityID] ?? []
    }

    func saveRename(name: String, key: IdentityRuleKey, pattern: String, kind: EntityKind) async -> Bool {
        isSavingRule = true
        renameError = nil
        defer { isSavingRule = false }
        do {
            let rule = IdentityRule(key: key, pattern: pattern, displayName: name, kind: kind)
            _ = try await client.save(rule: rule)
            await refresh()
            return true
        } catch {
            renameError = error.localizedDescription
            return false
        }
    }

    func loadBatteryHistory(range: BatteryHistoryRange) async {
        isLoadingBattery = true
        batteryError = nil
        defer { isLoadingBattery = false }
        do {
            client.connect()
            let end = Date()
            batteryReport = try await client.batteryHistory(start: range.start(before: end), end: end, resolution: range.resolution)
        } catch {
            batteryError = error.localizedDescription
        }
    }

    func loadBatteryDay(startingAt dayStart: Date) async {
        isLoadingBatteryDay = true
        defer { isLoadingBatteryDay = false }
        do {
            client.connect()
            let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86400)
            batteryDayReport = try await client.batteryHistory(start: dayStart, end: dayEnd, resolution: .hour)
        } catch {
            batteryError = error.localizedDescription
        }
    }

    func clearBatteryDay() {
        batteryDayReport = nil
    }

    func usageWindowChanged() {
        usageSummaries = []
        usageError = nil
        usageLoadedAt = nil
        Task { await refreshUsageIfStale() }
    }

    /// Averages move slowly by construction, so refreshing every 15 s is plenty.
    private func refreshUsageIfStale() async {
        guard let minutes = usageWindow.minutes else { return }
        if let loadedAt = usageLoadedAt, Date().timeIntervalSince(loadedAt) < 15 { return }
        do {
            usageSummaries = try await client.entityUsage(minutes: minutes)
            usageError = nil
            usageLoadedAt = Date()
        } catch {
            usageError = error.localizedDescription
        }
    }

    /// Appends this sample to every live entity's series and drops entities that
    /// have gone away, so the dictionary tracks the process table rather than
    /// growing for the life of the session.
    private func recordEntityHistory(_ entities: [EntityTelemetry]) {
        var next: [String: [Double]] = [:]
        next.reserveCapacity(entities.count)
        for entity in entities {
            var series = entityHistory[entity.entityID] ?? []
            series.append(entity.powerWatts)
            if series.count > Self.entityHistoryLength {
                series.removeFirst(series.count - Self.entityHistoryLength)
            }
            next[entity.entityID] = series
        }
        entityHistory = next
    }

    /// Whole-machine draw for the rail. Prefers the SMC system rail; the battery
    /// gauge is only a stand-in from pre-schema-5 collectors, and only on battery,
    /// where it equals the system load (on adapter it reads ~0 W at a charge hold).
    nonisolated static func drawWatts(_ snapshot: CollectorTelemetry) -> Double? {
        if let system = snapshot.systemPowerWatts { return system }
        return snapshot.onBattery ? snapshot.batteryWatts : nil
    }

    func history(for entityID: String) -> [Double] {
        entityHistory[entityID] ?? []
    }

    private func refresh() async {
        do {
            client.connect()
            try await client.setVisible(isLiveVisible)
            // Publishing only new samples matters: every assignment re-renders the
            // whole window, and polling and sampling run at the same period, so
            // about every other poll used to republish an identical snapshot.
            // The sequence check covers two refreshes overlapping (the window
            // returning while the poll loop is mid-fetch) so a sample isn't
            // appended to the traces twice.
            if let next = try await client.latestSnapshot(unlessSequence: snapshot?.sequence),
               next.sequence != snapshot?.sequence {
                // The traces plot readings evenly spaced. After time off screen,
                // splicing new readings onto old ones would draw an hour-old value
                // two seconds from now, so start the traces over instead.
                if let previous = snapshot?.timestamp, next.timestamp.timeIntervalSince(previous) > 60 {
                    wattsHistory.removeAll()
                    entityHistory.removeAll()
                }
                // Recorded on adapter as well as on battery: the trace is about
                // what the machine is doing, and it should not go blank the
                // moment you plug in.
                if let watts = Self.drawWatts(next) {
                    wattsHistory.append(WattReading(date: next.timestamp, watts: watts))
                    if wattsHistory.count > 150 { wattsHistory.removeFirst(wattsHistory.count - 150) }
                }
                let rows = next.entities + (next.powerBreakdown?.bucketEntities() ?? [])
                recordEntityHistory(rows)
                indexProcesses(next)
                liveEntities = rows
                snapshot = next
            }
            if connectionState != .live { connectionState = .live }
            retryDelaySeconds = 1
            await refreshUsageIfStale()
        } catch {
            client.invalidate()
            connectionState = .unavailable(error.localizedDescription)
            retryDelaySeconds = min(30, max(1, retryDelaySeconds * 2))
        }
    }
}
