import AppKit
import SwiftUI
import MimacIdentity

// DIRECTION CONTRACT — see DESIGN.md for the full system.
//
// THESIS: the ranked list of what is costing you something owns the window from
// the first pixel. Refuses the dashboard arrangement the category ships — a band
// of stat cards on top, the actual answer pushed below the fold.
// OWN-WORLD: graphite chassis, recessed wells for anything plotted, hairlines
// instead of shadows, square corners, every figure monospaced and tabular,
// colour only ever on data — channel hues on a row's own sparkline and cost bar.
// STORY: you open it mid-work, read the top row, and know what to close.
// FIRST VIEWPORT: a 250pt left rail carries system draw as a large readout over
// its live trace, then the vitals as a plain label/value list, then Mimac's own
// cost. Everything right of the rule is the table, dense and sorted by power.
// FORM: bench oscilloscope, candidate 4 of the resonance-ordered list, seed
// c6d353e7 — held to the calm register the user set, not literal instrument
// costume.

private enum UsageSortKey: Equatable {
    case name
    case power
    case activity
    case cpu
    case gpu
    case memory
    case disk
    case energy

    var caption: String {
        switch self {
        case .name: return "name"
        case .power: return "power"
        case .activity: return "activity"
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .memory: return "memory"
        case .disk: return "disk activity"
        case .energy: return "energy used"
        }
    }
}

/// Fixed column geometry, shared by the header and every row so the figures line
/// up in a true grid. Reading down a column is the whole point.
private enum Column {
    static let trend: CGFloat = 58
    static let power: CGFloat = 84
    static let activity: CGFloat = 78
    static let cpu: CGFloat = 52
    static let gpu: CGFloat = 48
    static let memory: CGFloat = 66
    static let disk: CGFloat = 74
    static let energy: CGFloat = 78
    static let gutter: CGFloat = 14
    static let inset: CGFloat = 16
}

struct LiveView: View {
    @EnvironmentObject private var model: LiveViewModel
    @State private var expandedEntities = Set<String>()
    @State private var renameDraft: RenameDraft?
    @State private var selectedWorkloadID: String?
    @State private var searchQuery = ""
    @State private var sortKey: UsageSortKey = .power
    @State private var sortAscending = false

    var body: some View {
        Group {
            if let snapshot = model.snapshot {
                HStack(spacing: 0) {
                    rail(snapshot)
                        .frame(width: 250)
                    Hairline(axis: .vertical)
                    ledger(snapshot)
                        .frame(maxWidth: .infinity)
                }
            } else {
                unavailableState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(item: $renameDraft) { draft in
            RenameSheet(draft: draft).environmentObject(model)
        }
    }

    // MARK: Rail
    //
    // Everything system-wide lives here so the table can own the window. The
    // order is the order you ask the questions in: how much, over what, and out
    // of what.

    private func rail(_ snapshot: CollectorTelemetry) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                drawSection(snapshot)
                Hairline()
                vitalsSection(snapshot)
                Hairline()
                selfReport(snapshot)
            }
        }
    }

    private func drawSection(_ snapshot: CollectorTelemetry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Eyebrow("System draw")
                Spacer(minLength: 4)
                Text(snapshot.onBattery ? "ON BATTERY" : "ON ADAPTER")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.7)
                    .foregroundStyle(Theme.inkFaint)
            }

            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(LiveViewModel.drawWatts(snapshot).map { String(format: "%.1f", $0) } ?? "—")
                    .font(Theme.figure(38, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink)
                    // No .numericText() transition: its digit blur is rendered on
                    // the CPU, and at one change every 2 s it was the app's single
                    // largest cost (~a third of its CPU while the window was open).
                Text("W")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(Theme.inkFaint)
            }

            Well {
                ZStack {
                    Graticule(divisions: 3)
                    if model.wattsHistory.count >= 2 {
                        Sparkline(
                            values: model.wattsHistory.map(\.watts),
                            tint: Theme.inkDim
                        )
                        .padding(.vertical, 3)
                    } else {
                        Text("Building the trace")
                            .font(Theme.entity(10.5))
                            .foregroundStyle(Theme.inkFaint)
                    }
                }
                .frame(height: 52)
                .frame(maxWidth: .infinity)
            }

            if let breakdown = snapshot.powerBreakdown {
                drawSplit(snapshot, breakdown)
            }

            Text(drawCaption(snapshot))
                .font(Theme.entity(11))
                .foregroundStyle(Theme.inkDim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 18)
    }

    /// The same four parts the table's Power column adds up to, so the total
    /// above never looks unexplained.
    private func drawSplit(_ snapshot: CollectorTelemetry, _ breakdown: PowerBreakdown) -> some View {
        let unreadable = snapshot.entities.first { $0.entityID == SyntheticEntity.unreadableProcessesID }
        let apps = snapshot.entities.reduce(0) { $1.entityID == SyntheticEntity.unreadableProcessesID ? $0 : $0 + $1.powerWatts }
        var parts: [(String, Double)] = [("Apps", apps)]
        if let unreadable, unreadable.gpuEnergyJoules != nil { parts.append(("System processes", unreadable.powerWatts)) }
        if let chip = breakdown.chipWatts { parts.append(("Memory & chip", chip)) }
        parts.append((breakdown.source == .rails ? "Display & rest of Mac" : "Rest of system", breakdown.restOfMacWatts))
        return VStack(spacing: 3) {
            ForEach(parts, id: \.0) { label, watts in
                HStack {
                    Text(label).font(Theme.entity(11)).foregroundStyle(Theme.inkDim)
                    Spacer(minLength: 8)
                    Text(String(format: "%.1f W", watts))
                        .font(Theme.figure(11))
                        .monospacedDigit()
                        .foregroundStyle(Theme.ink)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func drawCaption(_ snapshot: CollectorTelemetry) -> String {
        guard snapshot.onBattery else {
            return "Plugged in. Battery attribution resumes when you unplug."
        }
        let battery = snapshot.batteryPercent.map { "\($0)% left" } ?? "level unavailable"
        let remaining = Format.minutesRemaining(snapshot.estimatedBatteryMinutesRemaining)
        return remaining == "N/A" ? battery : "\(battery) · about \(remaining) remaining"
    }

    private func vitalsSection(_ snapshot: CollectorTelemetry) -> some View {
        VStack(spacing: 0) {
            vital("CPU", value: String(format: "%.0f", snapshot.systemCPUPercent), unit: "%", note: "all cores")
            vital("GPU", value: snapshot.systemGPUPercent.map { String(format: "%.0f", $0) } ?? "—", unit: "%", note: "system-wide")
            memoryVital(snapshot)
            vital("Disk", value: Format.rate(snapshot.diskReadBytesPerSecond + snapshot.diskWrittenBytesPerSecond), unit: nil, note: "read + write")
            vital("Network", value: snapshot.networkBytesPerSecond.map(Format.rate) ?? "—", unit: nil, note: snapshot.networkBytesPerSecond == nil ? "not available yet" : "system-wide")
            temperatureVital(snapshot)
        }
        .padding(.vertical, 4)
    }

    private func vital(
        _ label: String,
        value: String,
        unit: String?,
        note: String,
        tint: Color? = nil,
        help: String? = nil
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(Theme.entity(12, weight: .medium))
                    .foregroundStyle(Theme.ink)
                Text(note)
                    .font(Theme.entity(10))
                    .foregroundStyle(Theme.inkFaint)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(Theme.figure(13, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(tint ?? Theme.ink)
                if let unit {
                    Text(unit)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.inkFaint)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .help(help ?? "\(label): \(value) — \(note)")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label) \(value), \(note)")
    }

    /// How much memory is in use, not just how loudly the kernel is complaining
    /// about it. Pressure decides the tint; the number is what tells you whether
    /// to close something.
    private func memoryVital(_ snapshot: CollectorTelemetry) -> some View {
        guard let memory = snapshot.memory, memory.totalBytes > 0 else {
            return vital("Memory", value: pressureLabel(snapshot.memoryPressure), unit: nil, note: "pressure", tint: pressureTint(snapshot.memoryPressure))
        }
        return vital(
            "Memory",
            value: Format.memoryGB(memory.usedBytes),
            unit: nil,
            note: memoryNote(memory, pressure: snapshot.memoryPressure),
            tint: pressureTint(snapshot.memoryPressure),
            help: memoryHelp(memory, pressure: snapshot.memoryPressure)
        )
    }

    private func memoryNote(_ memory: MemoryReading, pressure: MemoryPressureLevel) -> String {
        let total = "of \(Format.memoryGB(memory.totalBytes, decimals: 0))"
        switch pressure {
        case .warning: return "\(total) · elevated"
        case .critical: return "\(total) · critical"
        case .normal, .unknown:
            // Swap in use is the honest tell that memory is tight even while the
            // kernel still calls pressure normal.
            guard memory.swapUsedBytes >= 1_073_741_824 else { return total }
            return "\(total) · \(Format.memoryGB(memory.swapUsedBytes)) swap"
        }
    }

    private func memoryHelp(_ memory: MemoryReading, pressure: MemoryPressureLevel) -> String {
        """
        App \(Format.memoryGB(memory.appBytes)) · Wired \(Format.memoryGB(memory.wiredBytes)) · \
        Compressed \(Format.memoryGB(memory.compressedBytes))
        Cached files \(Format.memoryGB(memory.cachedFilesBytes)) · Swap \(Format.memoryGB(memory.swapUsedBytes))
        Pressure \(pressureLabel(pressure).lowercased())
        """
    }

    /// The hotter of the two silicon sensors, noted with which one it is, so a
    /// hot machine says whether the CPU or the GPU is doing it.
    private func temperatureVital(_ snapshot: CollectorTelemetry) -> some View {
        guard let temperature = snapshot.temperature,
              let hottest = temperature.hottestSiliconCelsius else {
            return vital(
                "Temperature",
                value: thermalLabel(snapshot.thermalState),
                unit: nil,
                note: "system state",
                tint: thermalTint(snapshot.thermalState),
                help: temperatureHelp(snapshot.temperature, state: snapshot.thermalState)
            )
        }
        let source = temperature.hottestSiliconSource ?? "silicon"
        return vital(
            "Temperature",
            value: Format.celsius(hottest),
            unit: "°C",
            note: "\(source) · \(thermalLabel(snapshot.thermalState).lowercased())",
            tint: temperatureTint(hottest, state: snapshot.thermalState),
            help: temperatureHelp(temperature, state: snapshot.thermalState)
        )
    }

    /// Apple Silicon runs hot by design — sustained work in the seventies is
    /// normal and nothing is throttling. Warn in the high eighties, and call it
    /// out above 95, where the package starts pulling clocks back.
    private func temperatureTint(_ celsius: Double, state: ThermalLevel) -> Color? {
        if celsius >= 95 || state == .critical { return Theme.alarm }
        if celsius >= 85 || state == .serious { return Theme.caution }
        return nil
    }

    private func temperatureHelp(_ temperature: TemperatureReading?, state: ThermalLevel) -> String {
        guard let temperature else { return "No readable temperature sensors on this Mac" }
        var parts: [String] = []
        if let cpu = temperature.cpuCelsius { parts.append("CPU \(Format.celsius(cpu))°C") }
        if let gpu = temperature.gpuCelsius { parts.append("GPU \(Format.celsius(gpu))°C") }
        if let battery = temperature.batteryCelsius { parts.append("Battery \(Format.celsius(battery))°C") }
        if let enclosure = temperature.enclosureCelsius { parts.append("Enclosure \(Format.celsius(enclosure))°C") }
        let sensors = "\(temperature.sensorCount) sensor\(temperature.sensorCount == 1 ? "" : "s")"
        return """
        \(parts.joined(separator: " · "))
        Thermal state \(thermalLabel(state).lowercased()) · \(sensors), refreshed every 10 s
        """
    }

    /// The product reports on itself. A resource monitor that hides its own cost
    /// has not earned the right to report anyone else's.
    private func selfReport(_ snapshot: CollectorTelemetry) -> some View {
        // Collector plus this window. Reporting only the daemon under-stated the
        // cost of having Mimac open by roughly the app's own share.
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let app = snapshot.processes.first { $0.pid == ownPID }
        let cpu = snapshot.collectorCPUPercent + (app?.cpuPercent ?? 0)
        let memory = snapshot.collectorResidentBytes + (app?.residentBytes ?? 0)
        return VStack(alignment: .leading, spacing: 5) {
            Eyebrow("Mimac's own cost")
            Text("\(String(format: "%.1f", cpu))% CPU · \(Format.bytes(memory))")
                .font(Theme.figure(10.5))
                .foregroundStyle(Theme.inkFaint)
            if let app {
                Text("collector \(String(format: "%.1f", snapshot.collectorCPUPercent))% · app \(String(format: "%.1f", app.cpuPercent))%")
                    .font(Theme.figure(10.5))
                    .foregroundStyle(Theme.inkFaint)
            }
            Text("reading \(snapshot.processesObserved) processes")
                .font(Theme.entity(10.5))
                .foregroundStyle(Theme.inkFaint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private func pressureLabel(_ level: MemoryPressureLevel) -> String {
        switch level {
        case .normal: return "Normal"
        case .warning: return "Elevated"
        case .critical: return "Critical"
        case .unknown: return "—"
        }
    }

    private func pressureTint(_ level: MemoryPressureLevel) -> Color? {
        switch level {
        case .warning: return Theme.caution
        case .critical: return Theme.alarm
        default: return nil
        }
    }

    private func thermalLabel(_ level: ThermalLevel) -> String {
        switch level {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        case .unknown: return "—"
        }
    }

    private func thermalTint(_ level: ThermalLevel) -> Color? {
        switch level {
        case .serious: return Theme.caution
        case .critical: return Theme.alarm
        default: return nil
        }
    }

    // MARK: Ledger

    private func ledger(_ snapshot: CollectorTelemetry) -> some View {
        VStack(spacing: 0) {
            ledgerHeader(snapshot)
            Hairline()
            if model.usageWindow == .now {
                columnHeader
            } else {
                averagedColumnHeader
            }
            Hairline()
            ScrollView {
                if model.usageWindow == .now {
                    liveTable(snapshot)
                } else {
                    averagedTable
                }
            }
        }
    }

    private func ledgerHeader(_ snapshot: CollectorTelemetry) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("What's using this Mac")
                    .font(Theme.entity(15, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Text(ledgerCaption(snapshot))
                    .font(Theme.entity(11))
                    .foregroundStyle(Theme.inkFaint)
            }
            Spacer(minLength: 12)
            searchField
            if model.usageWindow == .now, !snapshot.workloads.isEmpty {
                workloadMenu(snapshot.workloads)
            }
            PillPicker(options: LiveViewModel.UsageWindow.allCases, title: \.rawValue, selection: $model.usageWindow)
                .onChange(of: model.usageWindow) { _, value in
                    if value != .now { selectedWorkloadID = nil }
                    if value != .now, sortKey == .activity || sortKey == .gpu {
                        sortKey = .power
                        sortAscending = false
                    }
                    model.usageWindowChanged()
                }
                .help("Now updates every 2 seconds; the averaged views rank by steady usage so the order holds still")
        }
        .padding(.horizontal, Column.inset)
        .padding(.vertical, 12)
    }

    private func ledgerCaption(_ snapshot: CollectorTelemetry) -> String {
        if model.usageWindow != .now {
            return "Sustained use over the last \(model.usageWindow.rawValue), by \(sortKey.caption)"
        }
        let count = filteredEntities(snapshot).filter { !SyntheticEntity.isPowerBucket($0.entityID) }.count
        let suffix = count == snapshot.entities.count ? "" : " of \(snapshot.entities.count)"
        return "\(count)\(suffix) apps and services, by \(sortKey.caption)"
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.inkFaint)
            TextField("Find an app", text: $searchQuery)
                .textFieldStyle(.plain)
                .font(Theme.entity(11))
            if !searchQuery.isEmpty {
                Button { searchQuery = "" } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.inkFaint)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .frame(width: 170, height: 26)
        .background(Theme.well)
        .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
    }

    private func workloadMenu(_ workloads: [WorkloadTelemetry]) -> some View {
        Menu {
            Button { selectedWorkloadID = nil } label: {
                Label("All projects", systemImage: selectedWorkloadID == nil ? "checkmark" : "folder")
            }
            Divider()
            ForEach(workloads.prefix(12), id: \.workloadID) { workload in
                Button { selectedWorkloadID = workload.workloadID } label: {
                    Label(workload.displayName, systemImage: selectedWorkloadID == workload.workloadID ? "checkmark" : "hammer")
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(selectedWorkloadName(in: workloads))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
            }
            .font(Theme.entity(11, weight: .medium))
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 9)
            .frame(height: 26)
            .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func selectedWorkloadName(in workloads: [WorkloadTelemetry]) -> String {
        workloads.first(where: { $0.workloadID == selectedWorkloadID })?.displayName ?? "All projects"
    }

    @ViewBuilder
    private func liveTable(_ snapshot: CollectorTelemetry) -> some View {
        let entities = filteredEntities(snapshot)
        if entities.isEmpty {
            emptyLine(searchQuery.isEmpty
                      ? "No processes resolved yet. The first sample lands within a few seconds."
                      : "Nothing matches “\(searchQuery)”.")
        } else {
            let maxWatts = entities.map(\.powerWatts).max() ?? 0
            // A LazyVStack, not a List: tried on 2026-11-05, the NSTableView behind
            // List re-measures and rebuilds moved rows on every 2-second re-sort,
            // which cost more than the lazy stack's per-row work.
            LazyVStack(spacing: 0) {
                ForEach(entities, id: \.entityID) { entity in
                    EntityRow(
                        entity: entity,
                        processes: model.processes(for: entity),
                        history: model.history(for: entity.entityID),
                        sampleInterval: snapshot.sampleIntervalSeconds,
                        maxWatts: maxWatts,
                        expanded: expandedEntities.contains(entity.entityID),
                        toggleExpanded: { toggle(entity.entityID) },
                        rename: { renameDraft = RenameDraft(entity: entity, process: model.processes(for: entity).first) }
                    )
                    Hairline()
                }
            }
        }
    }

    private func emptyLine(_ text: String) -> some View {
        Text(text)
            .font(Theme.entity(12))
            .foregroundStyle(Theme.inkFaint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Column.inset)
    }

    private func filteredEntities(_ snapshot: CollectorTelemetry) -> [EntityTelemetry] {
        var entities = model.liveEntities
        if let workloadID = selectedWorkloadID,
           let workload = snapshot.workloads.first(where: { $0.workloadID == workloadID }) {
            let members = Set(workload.entityIDs)
            entities = entities.filter { members.contains($0.entityID) }
        }
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            entities = entities.filter {
                $0.displayName.localizedCaseInsensitiveContains(query)
                    || ($0.project?.localizedCaseInsensitiveContains(query) ?? false)
            }
        }
        return entities.sorted(by: compareEntities)
    }

    @ViewBuilder
    private var averagedTable: some View {
        if model.usageSummaries.isEmpty {
            emptyLine(model.usageError ?? "Building averages. A few samples are enough — this view ranks by sustained usage, so the order stays put.")
        } else {
            let summaries = filteredUsageSummaries
            let maxWatts = summaries.map(\.averagePowerWatts).max() ?? 0
            if summaries.isEmpty {
                emptyLine("Nothing matches “\(searchQuery)”.")
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(summaries, id: \.id) { summary in
                        AveragedRow(summary: summary, icon: model.iconProcess(for: summary.entityID), maxWatts: maxWatts)
                        Hairline()
                    }
                }
            }
        }
    }

    private var filteredUsageSummaries: [EntityUsageSummary] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let summaries = query.isEmpty ? model.usageSummaries : model.usageSummaries.filter {
            $0.displayName.localizedCaseInsensitiveContains(query)
                || ($0.project?.localizedCaseInsensitiveContains(query) ?? false)
        }
        return summaries.sorted(by: compareSummaries)
    }

    // MARK: Column heads
    //
    // Units live in the head, never in the cells, so a column reads as a clean
    // stack of figures aligned on the decimal.

    private var columnHeader: some View {
        HStack(spacing: Column.gutter) {
            sortHeader("Name", nil, key: .name, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
            Eyebrow("Trend").frame(width: Column.trend, alignment: .leading)
            sortHeader("Power", "W", key: .power, alignment: .trailing).frame(width: Column.power, alignment: .trailing)
            sortHeader("Activity", nil, key: .activity, alignment: .leading).frame(width: Column.activity, alignment: .leading)
            sortHeader("CPU", "%", key: .cpu, alignment: .trailing).frame(width: Column.cpu, alignment: .trailing)
            sortHeader("GPU", "%", key: .gpu, alignment: .trailing).frame(width: Column.gpu, alignment: .trailing)
            sortHeader("Memory", nil, key: .memory, alignment: .trailing).frame(width: Column.memory, alignment: .trailing)
            sortHeader("Disk", nil, key: .disk, alignment: .trailing).frame(width: Column.disk, alignment: .trailing)
        }
        .padding(.horizontal, Column.inset)
        .padding(.vertical, 7)
    }

    private var averagedColumnHeader: some View {
        HStack(spacing: Column.gutter) {
            sortHeader("Name", nil, key: .name, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
            sortHeader("Avg power", "W", key: .power, alignment: .trailing).frame(width: Column.power, alignment: .trailing)
            sortHeader("Avg CPU", "%", key: .cpu, alignment: .trailing).frame(width: Column.cpu + 14, alignment: .trailing)
            sortHeader("Avg memory", nil, key: .memory, alignment: .trailing).frame(width: Column.memory + 14, alignment: .trailing)
            sortHeader("Disk", nil, key: .disk, alignment: .trailing).frame(width: Column.disk, alignment: .trailing)
            sortHeader("Energy", nil, key: .energy, alignment: .trailing).frame(width: Column.energy, alignment: .trailing)
        }
        .padding(.horizontal, Column.inset)
        .padding(.vertical, 7)
    }

    private func sortHeader(_ title: String, _ unit: String?, key: UsageSortKey, alignment: Alignment) -> some View {
        Button { selectSort(key) } label: {
            HStack(spacing: 4) {
                if alignment == .trailing, sortKey == key { sortCaret }
                Eyebrow(title, tint: sortKey == key ? Theme.ink : Theme.inkFaint)
                if let unit {
                    Text(unit)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Theme.inkFaint.opacity(0.8))
                }
                if alignment == .leading, sortKey == key { sortCaret }
            }
            .frame(maxWidth: .infinity, alignment: alignment)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(key == .power ? "Sort by estimated power and battery impact" : "Sort by \(title.lowercased())")
        .accessibilityLabel("Sort by \(title)")
        .accessibilityValue(sortKey == key ? (sortAscending ? "ascending" : "descending") : "not selected")
    }

    private var sortCaret: some View {
        Image(systemName: sortAscending ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill")
            .font(.system(size: 6))
            .foregroundStyle(Theme.inkDim)
    }

    private func selectSort(_ key: UsageSortKey) {
        if sortKey == key {
            sortAscending.toggle()
        } else {
            sortKey = key
            sortAscending = key == .name
        }
    }

    private func compareEntities(_ lhs: EntityTelemetry, _ rhs: EntityTelemetry) -> Bool {
        let order: ComparisonResult
        switch sortKey {
        case .name:
            order = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
        case .power:
            order = compare(lhs.powerWatts, rhs.powerWatts)
        case .activity:
            order = compare(activityRank(lhs.activityLevel), activityRank(rhs.activityLevel))
        case .cpu:
            order = compare(lhs.cpuPercent, rhs.cpuPercent)
        case .gpu:
            return compareOptional(lhs.gpuPercent, rhs.gpuPercent, lhsName: lhs.displayName, rhsName: rhs.displayName)
        case .memory:
            order = compare(lhs.residentBytes, rhs.residentBytes)
        case .disk:
            order = compare(lhs.diskReadBytes + lhs.diskWrittenBytes, rhs.diskReadBytes + rhs.diskWrittenBytes)
        case .energy:
            order = compare(lhs.energyJoules, rhs.energyJoules)
        }
        return ordered(order, lhsName: lhs.displayName, rhsName: rhs.displayName)
    }

    private func compareSummaries(_ lhs: EntityUsageSummary, _ rhs: EntityUsageSummary) -> Bool {
        let order: ComparisonResult
        switch sortKey {
        case .name:
            order = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
        case .cpu:
            order = compare(lhs.averageCPUPercent, rhs.averageCPUPercent)
        case .memory:
            order = compare(lhs.averageResidentBytes, rhs.averageResidentBytes)
        case .disk:
            order = compare(lhs.diskBytesPerSecond, rhs.diskBytesPerSecond)
        case .energy:
            order = compare(lhs.energyJoules, rhs.energyJoules)
        case .power, .activity, .gpu:
            order = compare(lhs.averagePowerWatts, rhs.averagePowerWatts)
        }
        return ordered(order, lhsName: lhs.displayName, rhsName: rhs.displayName)
    }

    private func compare<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        lhs == rhs ? .orderedSame : (lhs < rhs ? .orderedAscending : .orderedDescending)
    }

    private func ordered(_ order: ComparisonResult, lhsName: String, rhsName: String) -> Bool {
        if order == .orderedSame {
            return lhsName.localizedCaseInsensitiveCompare(rhsName) == .orderedAscending
        }
        return sortAscending ? order == .orderedAscending : order == .orderedDescending
    }

    private func compareOptional(_ lhs: Double?, _ rhs: Double?, lhsName: String, rhsName: String) -> Bool {
        switch (lhs, rhs) {
        case let (left?, right?): return ordered(compare(left, right), lhsName: lhsName, rhsName: rhsName)
        case (_?, nil): return true
        case (nil, _?): return false
        case (nil, nil): return lhsName.localizedCaseInsensitiveCompare(rhsName) == .orderedAscending
        }
    }

    private func activityRank(_ level: ActivityLevel) -> Int {
        switch level {
        case .idle: return 0
        case .low: return 1
        case .medium: return 2
        case .high: return 3
        case .veryHigh: return 4
        case .abnormal: return 5
        }
    }

    // MARK: States

    private var unavailableState: some View {
        VStack(spacing: 12) {
            if model.connectionState == .connecting || model.connectionState == .live {
                ProgressView().controlSize(.small)
                Text("Connecting to the collector…")
                    .font(Theme.entity(12))
                    .foregroundStyle(Theme.inkDim)
            } else {
                Text("The collector isn't running")
                    .font(Theme.entity(16, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Text(unavailableMessage)
                    .font(Theme.entity(12))
                    .foregroundStyle(Theme.inkDim)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
                HStack(spacing: 8) {
                    Button("Start collector") { model.startDaemon() }
                        .buttonStyle(ProminentButtonStyle())
                    Button("Try again") { model.retryNow() }
                        .buttonStyle(SubtleButtonStyle())
                }
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    private var unavailableMessage: String {
        if case .unavailable(let message) = model.connectionState { return message }
        return "Waiting for the first telemetry sample."
    }

    private func toggle(_ id: String) {
        if expandedEntities.contains(id) { expandedEntities.remove(id) } else { expandedEntities.insert(id) }
    }
}

// MARK: - Rows

private struct EntityRow: View {
    let entity: EntityTelemetry
    let processes: [ProcessTelemetry]
    let history: [Double]
    let sampleInterval: Double
    let maxWatts: Double
    let expanded: Bool
    let toggleExpanded: () -> Void
    let rename: () -> Void
    @State private var hovering = false

    /// Colour is earned by mattering: below this the row's marks stay neutral, so
    /// two hundred idle services never become a colour field.
    private var carriesChannel: Bool { entity.powerWatts >= 0.005 }
    private var tint: Color { carriesChannel ? Theme.channel(for: entity.entityID) : Theme.inkFaint }
    /// CPU and GPU only: the row exists because those processes cannot be read.
    private var isUnreadable: Bool { entity.entityID == SyntheticEntity.unreadableProcessesID }
    /// Hardware, not processes: power only.
    private var isBucket: Bool { SyntheticEntity.isPowerBucket(entity.entityID) }
    /// The unreadable row has power only when the chip rails were readable;
    /// the collector marks that by giving it a GPU energy figure.
    private var hasPower: Bool { !isUnreadable || entity.gpuEnergyJoules != nil }
    /// The GPU share is a measured rail split by measured GPU time: drawn as
    /// the estimated part of the bar.
    private var gpuWatts: Double { (entity.gpuEnergyJoules ?? 0) / max(0.001, sampleInterval) }

    private var caption: String {
        switch entity.entityID {
        case SyntheticEntity.chipID: return "Memory, fabric, power delivery"
        case SyntheticEntity.restOfMacID:
            return entity.displayName == "Rest of system"
                ? "Not broken down on this Mac"
                : "Display, storage, Wi-Fi, audio"
        case SyntheticEntity.unreadableProcessesID: return "\(entity.processCount) processes · no memory or disk"
        default: return entity.project ?? "\(entity.processCount) process\(entity.processCount == 1 ? "" : "es")"
        }
    }

    private var explanation: String? {
        switch entity.entityID {
        case SyntheticEntity.unreadableProcessesID:
            return """
            Total CPU minus every process Mimac can read. macOS only lets admin tools \
            read root-owned processes such as WindowServer, kernel_task and coreaudiod, \
            so their CPU appears here as one figure, along with processes that started \
            or exited mid-sample. GPU comes from the graphics driver, which reports them all. \
            Power is the CPU power rail minus every readable process, plus their share of the GPU rail.
            """
        case SyntheticEntity.chipID:
            return """
            The chip's supply minus the CPU and GPU rails: memory, the media and \
            neural engines, the fabric that connects them, and the chip's voltage \
            regulators, which waste more as load rises. Includes GPU power while no app \
            is using the GPU. Measured, but not traceable to any one process.
            """
        case SyntheticEntity.restOfMacID:
            return entity.displayName == "Rest of system"
                ? "System draw minus every row above. This Mac doesn't publish the chip power rails Mimac uses to break it down."
                : """
                System draw minus the chip: the display backlight (usually most of it at \
                idle), storage, Wi-Fi and Bluetooth, audio, and power conversion losses, \
                which grow by a watt or two under heavy load. Lower the brightness and \
                watch this row.
                """
        default:
            return nil
        }
    }

    private var bucketSymbol: String? {
        switch entity.entityID {
        case SyntheticEntity.chipID: return "memorychip"
        case SyntheticEntity.restOfMacID: return "laptopcomputer"
        default: return nil
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Button(action: toggleExpanded) {
                HStack(spacing: Column.gutter) {
                    HStack(spacing: 9) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                            .foregroundStyle(hovering || expanded ? Theme.inkDim : Theme.inkFaint.opacity(0.55))
                            .frame(width: 9)
                            .accessibilityHidden(true)
                        EntityIcon(process: processes.first, kind: entity.kind, symbolOverride: bucketSymbol)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(entity.displayName)
                                    .font(Theme.entity(13, weight: .medium))
                                    .foregroundStyle(Theme.ink)
                                    .lineLimit(1)
                                if entity.groupedAutomatically {
                                    Text("grouped")
                                        .font(.system(size: 9))
                                        .foregroundStyle(Theme.inkFaint)
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1)
                                        .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
                                        .help("Grouped by heuristics. Right-click to correct it")
                                }
                            }
                            Text(caption)
                                .font(Theme.entity(10.5))
                                .foregroundStyle(Theme.inkFaint)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Group {
                        if carriesChannel, history.count >= 2 {
                            Sparkline(values: history, tint: tint)
                        } else {
                            Color.clear
                        }
                    }
                    .frame(width: Column.trend, height: 16)

                    VStack(alignment: .trailing, spacing: 3) {
                        if hasPower {
                            Figure(Format.wattsPrecise(entity.powerWatts), emphasized: true)
                            EnergyBar(
                                measured: max(0, entity.powerWatts - gpuWatts),
                                estimated: min(gpuWatts, entity.powerWatts),
                                scale: maxWatts,
                                tint: tint
                            )
                        } else {
                            Figure("—")
                        }
                    }
                    .frame(width: Column.power, alignment: .trailing)

                    // Activity grades apps; on the scale a lit display alone reads
                    // "Very high", which says nothing about the hardware rows.
                    Group {
                        if isBucket {
                            Figure("—")
                        } else {
                            ActivityLabel(level: entity.activityLevel, cause: entity.activityCause)
                        }
                    }
                    .frame(width: Column.activity, alignment: .leading)
                    Figure(isBucket ? "—" : Format.percent(entity.cpuPercent)).frame(width: Column.cpu, alignment: .trailing)
                    Figure(isBucket ? "—" : entity.gpuPercent.map(Format.percent) ?? "—").frame(width: Column.gpu, alignment: .trailing)
                    Figure(isUnreadable || isBucket ? "—" : Format.bytes(entity.residentBytes)).frame(width: Column.memory, alignment: .trailing)
                    Figure(isUnreadable || isBucket ? "—" : Format.rate(Double(entity.diskReadBytes + entity.diskWrittenBytes) / max(0.001, sampleInterval)))
                        .frame(width: Column.disk, alignment: .trailing)
                }
                .padding(.horizontal, Column.inset)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(hovering ? Theme.hover : .clear)
            .onHover { hovering = $0 }
            .contextMenu {
                if !isUnreadable && !isBucket {
                    Button("Rename…", action: rename)
                    Button(expanded ? "Collapse processes" : "Show processes", action: toggleExpanded)
                }
            }

            if expanded {
                VStack(spacing: 0) {
                    if !isBucket {
                        HStack(spacing: 16) {
                            Text("GPU \(entity.gpuPercent.map { Format.percent($0) + "%" } ?? "not available")")
                            if entity.gpuEnergyJoules != nil {
                                Text("GPU power \(Format.wattsPrecise(gpuWatts)) W, estimated")
                            }
                            Text("Network \(entity.networkBytesPerSecond.map(Format.rate) ?? "not available")")
                            if !isUnreadable {
                                Text("\(processes.count) process\(processes.count == 1 ? "" : "es")")
                            }
                            Spacer()
                        }
                        .font(Theme.figure(10))
                        .foregroundStyle(Theme.inkFaint)
                        .padding(.bottom, 6)
                    }
                    if let explanation {
                        Text(explanation)
                            .font(Theme.entity(11))
                            .foregroundStyle(Theme.inkDim)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ForEach(processes, id: \.pid) { process in
                            ProcessDetailRow(process: process, sampleInterval: sampleInterval)
                        }
                    }
                }
                .padding(.horizontal, Column.inset + 18)
                .padding(.bottom, 10)
            }
        }
    }
}

private struct AveragedRow: View {
    let summary: EntityUsageSummary
    let icon: ProcessTelemetry?
    let maxWatts: Double
    @State private var hovering = false

    private var tint: Color {
        summary.averagePowerWatts >= 0.005 ? Theme.channel(for: summary.entityID) : Theme.inkFaint
    }
    private var isUnreadable: Bool { summary.entityID == SyntheticEntity.unreadableProcessesID }
    /// Hardware, not processes: power and energy only.
    private var isBucket: Bool { SyntheticEntity.isPowerBucket(summary.entityID) }

    private var bucketSymbol: String? {
        switch summary.entityID {
        case SyntheticEntity.chipID: return "memorychip"
        case SyntheticEntity.restOfMacID: return "laptopcomputer"
        default: return nil
        }
    }

    private var caption: String {
        switch summary.entityID {
        case SyntheticEntity.chipID: return "Memory, fabric, power delivery"
        case SyntheticEntity.restOfMacID:
            return summary.displayName == "Rest of system" ? "Not broken down on this Mac" : "Display, storage, Wi-Fi, audio"
        default: return summary.project ?? activeCaption
        }
    }

    var body: some View {
        HStack(spacing: Column.gutter) {
            HStack(spacing: 9) {
                Color.clear.frame(width: 9)
                EntityIcon(process: icon, kind: summary.kind, symbolOverride: bucketSymbol)
                VStack(alignment: .leading, spacing: 1) {
                    Text(summary.displayName)
                        .font(Theme.entity(13, weight: .medium))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    Text(caption)
                        .font(Theme.entity(10.5))
                        .foregroundStyle(Theme.inkFaint)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 3) {
                // Older history has no energy for the unreadable row; from
                // schema 6 it carries the CPU rail's remainder.
                if isUnreadable && summary.energyJoules <= 0 {
                    Figure("—")
                } else {
                    Figure(Format.wattsPrecise(summary.averagePowerWatts), emphasized: true)
                    EnergyBar(measured: summary.averagePowerWatts, estimated: 0, scale: maxWatts, tint: tint)
                }
            }
            .frame(width: Column.power, alignment: .trailing)
            Figure(isBucket ? "—" : Format.percent(summary.averageCPUPercent)).frame(width: Column.cpu + 14, alignment: .trailing)
            Figure(isUnreadable || isBucket ? "—" : Format.bytes(UInt64(max(0, summary.averageResidentBytes)))).frame(width: Column.memory + 14, alignment: .trailing)
            Figure(isUnreadable || isBucket ? "—" : Format.rate(summary.diskBytesPerSecond)).frame(width: Column.disk, alignment: .trailing)
            Figure(isUnreadable && summary.energyJoules <= 0 ? "—" : Format.energy(summary.energyJoules)).frame(width: Column.energy, alignment: .trailing)
        }
        .padding(.horizontal, Column.inset)
        .padding(.vertical, 8)
        .background(hovering ? Theme.hover : .clear)
        .onHover { hovering = $0 }
    }

    private var activeCaption: String {
        summary.activeSeconds < summary.windowSeconds * 0.9
            ? "active \(Format.duration(summary.activeSeconds)) of \(Format.duration(summary.windowSeconds))"
            : "active the whole window"
    }
}

private struct Figure: View {
    let value: String
    var emphasized = false
    init(_ value: String, emphasized: Bool = false) {
        self.value = value
        self.emphasized = emphasized
    }
    var body: some View {
        Text(value)
            .font(Theme.figure(11.5, weight: emphasized ? .medium : .regular))
            .monospacedDigit()
            .foregroundStyle(emphasized ? Theme.ink : Theme.inkDim)
            .lineLimit(1)
    }
}

/// A word, in the colour its condition earns. No pill, no dot — the word is the
/// state, and colour only reinforces it.
private struct ActivityLabel: View {
    let level: ActivityLevel
    let cause: String?

    var body: some View {
        Text(label)
            .font(Theme.entity(11, weight: level == .idle ? .regular : .medium))
            .foregroundStyle(color)
            .lineLimit(1)
            .help(cause ?? label)
            .accessibilityLabel("Activity \(label)")
    }

    private var label: String {
        switch level {
        case .idle: return "Idle"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .veryHigh: return "Very high"
        case .abnormal: return "Abnormal"
        }
    }

    private var color: Color {
        switch level {
        case .idle: return Theme.inkFaint
        case .low, .medium: return Theme.inkDim
        case .high: return Theme.caution
        case .veryHigh, .abnormal: return Theme.alarm
        }
    }
}

private struct ProcessDetailRow: View {
    let process: ProcessTelemetry
    let sampleInterval: Double
    @State private var showRaw = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text("\(process.pid)")
                    .font(Theme.figure(10))
                    .foregroundStyle(Theme.inkFaint)
                    .frame(width: 46, alignment: .leading)
                Text(process.name)
                    .font(Theme.entity(11.5))
                    .foregroundStyle(Theme.inkDim)
                    .lineLimit(1)
                Spacer()
                Figure(Format.percent(process.cpuPercent))
                Figure(Format.bytes(process.residentBytes))
                Figure(Format.wattsPrecise(process.energyJoules / max(0.001, sampleInterval)))
                Button(showRaw ? "Less" : "Details") { showRaw.toggle() }
                    .buttonStyle(.plain)
                    .font(Theme.entity(10, weight: .medium))
                    .foregroundStyle(Theme.inkDim)
            }
            if showRaw {
                VStack(alignment: .leading, spacing: 3) {
                    RawField(label: "Path", value: process.path ?? "not available")
                    RawField(label: "Args", value: process.arguments?.joined(separator: " ") ?? "not available")
                    RawField(label: "CWD", value: process.cwd ?? "not available")
                    RawField(label: "Ports", value: process.listeningPorts.isEmpty ? "none" : process.listeningPorts.map(String.init).joined(separator: ", "))
                    RawField(label: "Signed", value: process.identity.signingIdentifier ?? process.identity.teamIdentifier ?? "not available")
                }
                .padding(.leading, 56)
                .padding(.bottom, 4)
            }
        }
        .padding(.vertical, 5)
        .overlay(alignment: .top) { Hairline() }
    }
}

private struct RawField: View {
    let label: String
    let value: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label)
                .frame(width: 44, alignment: .leading)
                .foregroundStyle(Theme.inkFaint)
            Text(value)
                .foregroundStyle(Theme.inkDim)
                .textSelection(.enabled)
        }
        .font(Theme.figure(10))
    }
}

/// The real app icon, uncontained. The previous design sat every icon in a
/// gradient tile; the icon is already the identity and needs no jewellery.
private struct EntityIcon: View {
    static let cache = NSCache<NSString, NSImage>()
    let process: ProcessTelemetry?
    let kind: EntityKind
    var symbolOverride: String? = nil

    var body: some View {
        Group {
            if let icon = cachedIcon {
                Image(nsImage: icon).resizable().scaledToFit()
            } else if let iconName = process?.identity.iconName {
                ToolIdentityIcon(name: iconName)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.inkFaint)
            }
        }
        .frame(width: 17, height: 17)
        .accessibilityHidden(true)
    }

    private var cachedIcon: NSImage? {
        guard let path = process?.identity.iconPath else { return nil }
        if let cached = Self.cache.object(forKey: path as NSString) { return cached }
        guard let image = NSImage(contentsOfFile: path) else { return nil }
        Self.cache.setObject(image, forKey: path as NSString)
        return image
    }

    private var symbol: String {
        if let symbolOverride { return symbolOverride }
        switch kind {
        case .app: return "square.dashed"
        case .devServer: return "terminal"
        case .agent: return "sparkle"
        case .helper: return "gearshape"
        case .system: return "cpu"
        case .unknown: return "questionmark"
        }
    }
}

// MARK: - Rename

struct RenameDraft: Identifiable {
    let id = UUID()
    let entity: EntityTelemetry
    let process: ProcessTelemetry?
}

private struct RenameSheet: View {
    @EnvironmentObject private var model: LiveViewModel
    @Environment(\.dismiss) private var dismiss
    let draft: RenameDraft
    @State private var name: String
    @State private var key: IdentityRuleKey
    @State private var pattern: String

    init(draft: RenameDraft) {
        self.draft = draft
        let suggestion = Self.suggestion(for: draft)
        _name = State(initialValue: draft.entity.displayName)
        _key = State(initialValue: suggestion.key)
        _pattern = State(initialValue: suggestion.pattern)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Rename this entity")
                    .font(Theme.entity(16, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Text("Mimac saves this as a rule, so the name sticks across restarts.")
                    .font(Theme.entity(12))
                    .foregroundStyle(Theme.inkDim)
            }
            VStack(alignment: .leading, spacing: 10) {
                LabeledField(label: "Display name") { TextField("Name", text: $name) }
                LabeledField(label: "Match using") {
                    Picker("Match using", selection: $key) {
                        ForEach(IdentityRuleKey.allCases, id: \.self) { Text(Self.title($0)).tag($0) }
                    }
                    .labelsHidden()
                    .onChange(of: key) { _, newKey in pattern = Self.pattern(for: newKey, draft: draft) }
                }
                LabeledField(label: "Match value") { TextField("Pattern", text: $pattern) }
            }
            .textFieldStyle(.roundedBorder)
            if let error = model.renameError {
                Text(error).font(Theme.entity(11)).foregroundStyle(Theme.alarm)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(SubtleButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button(model.isSavingRule ? "Saving…" : "Save rule") {
                    Task {
                        if await model.saveRename(name: name, key: key, pattern: pattern, kind: draft.entity.kind) {
                            dismiss()
                        }
                    }
                }
                .buttonStyle(ProminentButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || pattern.isEmpty || model.isSavingRule)
            }
        }
        .padding(22)
        .frame(width: 440)
        .background(Theme.panel)
    }

    private static func suggestion(for draft: RenameDraft) -> (key: IdentityRuleKey, pattern: String) {
        if let bundle = draft.process?.identity.bundleIdentifier { return (.bundleIdentifier, bundle) }
        if let root = draft.process?.identity.projectRoot { return (.projectDirectory, root) }
        if let path = draft.process?.path { return (.executablePath, path) }
        return (.commandPattern, "*\(draft.process?.name ?? draft.entity.displayName)*")
    }

    private static func pattern(for key: IdentityRuleKey, draft: RenameDraft) -> String {
        switch key {
        case .executablePath: return draft.process?.path ?? ""
        case .commandPattern: return "*\(draft.process?.name ?? draft.entity.displayName)*"
        case .projectDirectory: return draft.process?.identity.projectRoot ?? draft.process?.cwd ?? ""
        case .bundleIdentifier: return draft.process?.identity.bundleIdentifier ?? ""
        case .parentEntityID: return draft.process?.parentChain.first.flatMap(String.init) ?? ""
        case .listeningPort: return draft.process?.listeningPorts.first.map(String.init) ?? ""
        }
    }

    private static func title(_ key: IdentityRuleKey) -> String {
        switch key {
        case .executablePath: return "Executable path"
        case .commandPattern: return "Command pattern"
        case .projectDirectory: return "Project directory"
        case .bundleIdentifier: return "Bundle identifier"
        case .parentEntityID: return "Parent entity"
        case .listeningPort: return "Listening port"
        }
    }
}

private struct LabeledField<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Eyebrow(label)
            content
        }
    }
}
