import Charts
import SwiftUI
import MimacIdentity

/// Fixed column geometry for the attribution table, shared by head and rows.
private enum BatteryColumn {
    static let energy: CGFloat = 150
    static let battery: CGFloat = 62
    static let share: CGFloat = 54
    static let confidence: CGFloat = 74
    static let gutter: CGFloat = 14
    static let inset: CGFloat = 18
}

struct BatteryHistoryView: View {
    @EnvironmentObject private var model: LiveViewModel
    @State private var range: BatteryHistoryRange = .hour
    @State private var selectedDay: Date?
    @State private var expanded = Set<String>()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: range) {
            selectedDay = nil
            model.clearBatteryDay()
            // Refresh every minute while this screen is open; a new attribution
            // window lands each unplugged minute.
            while !Task.isCancelled {
                await model.loadBatteryHistory(range: range)
                try? await Task.sleep(for: .seconds(60))
            }
        }
        .task(id: selectedDay) {
            if let selectedDay { await model.loadBatteryDay(startingAt: selectedDay) }
        }
        .onChange(of: model.connectionState) { _, state in
            if state == .live, model.batteryReport == nil {
                Task { await model.loadBatteryHistory(range: range) }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Where the battery went")
                    .font(Theme.entity(15, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Text("Measured at the gas gauge, with confidence on every estimate")
                    .font(Theme.entity(11))
                    .foregroundStyle(Theme.inkFaint)
            }
            Spacer()
            if model.isLoadingBattery, model.batteryReport != nil {
                ProgressView().controlSize(.small)
            }
            PillPicker(options: BatteryHistoryRange.allCases, title: \.title, selection: $range)
            Button {
                Task { await model.loadBatteryHistory(range: range) }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.inkDim)
                    .frame(width: 26, height: 24)
                    .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("Refresh now")
            .accessibilityLabel("Refresh battery history")
        }
        .padding(.horizontal, BatteryColumn.inset)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var content: some View {
        if let report = model.batteryReport {
            if report.attributedDurationSeconds > 0 || report.excludedDurationSeconds > 0 {
                loadedContent(report)
            } else {
                emptyState(
                    title: "No battery time in this range yet",
                    message: "Attribution starts after the first full minute running on battery. Unplug the charger and check back."
                )
            }
        } else if model.isLoadingBattery {
            VStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Reading battery history…")
                    .font(Theme.entity(12))
                    .foregroundStyle(Theme.inkDim)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            emptyState(
                title: "Couldn't load battery history",
                message: model.batteryError ?? "The collector didn't reply.",
                retry: true
            )
        }
    }

    private func loadedContent(_ report: BatteryHistoryReport) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                statRow(report)
                Hairline()
                chartSection(report)
                Hairline()
                if selectedDay != nil {
                    dayDetailSection
                    Hairline()
                }
                tableSection(report)
            }
        }
    }

    // MARK: Stats

    private func statRow(_ report: BatteryHistoryReport) -> some View {
        HStack(spacing: 0) {
            StatReadout(
                label: "Estimated drain",
                value: Format.percent(report.totalBatteryPercent),
                unit: "%",
                detail: Format.wattHours(report.totalDrainJoules)
            )
            Hairline(axis: .vertical).frame(height: 44)
            StatReadout(
                label: "On battery",
                value: Format.duration(report.attributedDurationSeconds),
                unit: nil,
                detail: "attributed time"
            )
            Hairline(axis: .vertical).frame(height: 44)
            StatReadout(
                label: "Counter gap",
                value: String(format: "%.0f", report.reconciliationErrorPercent),
                unit: "%",
                detail: "energy outside process counters"
            )
            Hairline(axis: .vertical).frame(height: 44)
            StatReadout(
                label: "Excluded",
                value: Format.duration(report.excludedDurationSeconds),
                unit: nil,
                detail: "charging, sleep, plugged in"
            )
        }
        .padding(.vertical, 16)
    }

    // MARK: Charts

    private func chartSection(_ report: BatteryHistoryReport) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Eyebrow(report.resolution == .day ? "Drain per day" : "Drain rate")
                Spacer()
                if report.resolution == .day {
                    Text("Click a day to open its hours")
                        .font(Theme.entity(11))
                        .foregroundStyle(Theme.inkFaint)
                } else if report.excludedDurationSeconds > 0 {
                    Text("Gaps are excluded time — charging or asleep")
                        .font(Theme.entity(11))
                        .foregroundStyle(Theme.inkFaint)
                }
            }
            Well {
                Group {
                    if report.resolution == .day {
                        dailyBars(report)
                    } else {
                        drainChart(report)
                    }
                }
                .padding(10)
            }
        }
        .padding(.horizontal, BatteryColumn.inset)
        .padding(.vertical, 16)
    }

    private struct SegmentedPoint: Identifiable {
        let id: Date
        let point: BatteryDrainPoint
        let segment: Int
    }

    /// Breaks the drain line at excluded windows so charging and sleep read as
    /// honest gaps instead of interpolated drain.
    private func segments(_ timeline: [BatteryDrainPoint]) -> [SegmentedPoint] {
        var result: [SegmentedPoint] = []
        var segment = 0
        var previousWasDrain = false
        for point in timeline {
            if point.drainWatts != nil {
                if !previousWasDrain { segment += 1 }
                result.append(SegmentedPoint(id: point.timestamp, point: point, segment: segment))
                previousWasDrain = true
            } else {
                previousWasDrain = false
            }
        }
        return result
    }

    private func drainChart(_ report: BatteryHistoryReport) -> some View {
        Chart(segments(report.timeline)) { item in
            if let watts = item.point.drainWatts {
                AreaMark(
                    x: .value("Time", item.id),
                    y: .value("Watts", watts),
                    series: .value("Segment", item.segment)
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(Theme.inkDim.opacity(0.14))
                LineMark(
                    x: .value("Time", item.id),
                    y: .value("Watts", watts),
                    series: .value("Segment", item.segment)
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(Theme.inkDim)
                .lineStyle(StrokeStyle(lineWidth: 1))
            }
        }
        .chartYAxisLabel("W", position: .trailing)
        .chartYAxis { AxisMarks { AxisGridLine().foregroundStyle(Theme.graticule); AxisValueLabel().foregroundStyle(Theme.inkFaint) } }
        .chartXAxis { AxisMarks { AxisValueLabel().foregroundStyle(Theme.inkFaint) } }
        .frame(height: 150)
    }

    private func dailyBars(_ report: BatteryHistoryReport) -> some View {
        Chart(report.timeline) { point in
            if let joules = point.drainJoules {
                BarMark(
                    x: .value("Day", point.timestamp, unit: .day),
                    y: .value("Wh", joules / 3600)
                )
                .foregroundStyle(barColor(for: point.timestamp))
            }
        }
        .chartYAxisLabel("Wh", position: .trailing)
        .chartYAxis { AxisMarks { AxisGridLine().foregroundStyle(Theme.graticule); AxisValueLabel().foregroundStyle(Theme.inkFaint) } }
        .chartXAxis { AxisMarks { AxisValueLabel().foregroundStyle(Theme.inkFaint) } }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onTapGesture { location in
                        guard let plotFrame = proxy.plotFrame else { return }
                        let x = location.x - geometry[plotFrame].origin.x
                        guard let date: Date = proxy.value(atX: x) else { return }
                        select(day: Calendar.current.startOfDay(for: date), in: model.batteryReport)
                    }
            }
        }
        .frame(height: 150)
    }

    private func barColor(for timestamp: Date) -> Color {
        guard let selectedDay else { return Theme.inkDim }
        return Calendar.current.isDate(timestamp, inSameDayAs: selectedDay) ? Theme.ink : Theme.inkDim.opacity(0.3)
    }

    private func select(day: Date, in report: BatteryHistoryReport?) {
        guard let report else { return }
        let hasData = report.timeline.contains {
            Calendar.current.isDate($0.timestamp, inSameDayAs: day) && $0.drainJoules != nil
        }
        guard hasData else { return }
        let toggledOff = selectedDay == day
        selectedDay = toggledOff ? nil : day
        if toggledOff { model.clearBatteryDay() }
    }

    private var dayDetailSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if let selectedDay {
                    Text(selectedDay, format: .dateTime.weekday(.wide).month().day())
                        .font(Theme.entity(13, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                }
                Eyebrow("hour by hour")
                Spacer()
                Button("Show the whole range") {
                    selectedDay = nil
                    model.clearBatteryDay()
                }
                .buttonStyle(.plain)
                .font(Theme.entity(11, weight: .medium))
                .foregroundStyle(Theme.inkDim)
            }
            Well {
                Group {
                    if let day = model.batteryDayReport {
                        Chart(day.timeline) { point in
                            if let joules = point.drainJoules {
                                BarMark(x: .value("Hour", point.timestamp, unit: .hour), y: .value("Wh", joules / 3600))
                                    .foregroundStyle(Theme.inkDim)
                            }
                        }
                        .chartYAxisLabel("Wh", position: .trailing)
                        .chartYAxis { AxisMarks { AxisGridLine().foregroundStyle(Theme.graticule); AxisValueLabel().foregroundStyle(Theme.inkFaint) } }
                        .chartXAxis { AxisMarks { AxisValueLabel().foregroundStyle(Theme.inkFaint) } }
                        .frame(height: 110)
                    } else if model.isLoadingBatteryDay {
                        HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
                            .frame(height: 110)
                    } else {
                        Text("Couldn't load this day. Try again in a moment.")
                            .font(Theme.entity(12))
                            .foregroundStyle(Theme.inkFaint)
                            .frame(height: 110)
                    }
                }
                .padding(10)
            }
        }
        .padding(.horizontal, BatteryColumn.inset)
        .padding(.vertical, 16)
    }

    // MARK: Attribution table

    private func tableSection(_ report: BatteryHistoryReport) -> some View {
        let dayReport = selectedDay != nil ? model.batteryDayReport : nil
        let rows = (dayReport ?? report).rows
        let maxJoules = rows.map(\.totalJoules).max() ?? 0
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(dayReport != nil ? "Where it went that day" : "Where it went")
                    .font(Theme.entity(15, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Text("Solid bars are measured energy; hatched bars are estimated. Unattributed energy stays visible and is never forced onto apps.")
                    .font(Theme.entity(11))
                    .foregroundStyle(Theme.inkFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, BatteryColumn.inset)
            .padding(.vertical, 14)

            Hairline()
            columnHeader
            Hairline()
            if rows.isEmpty {
                Text("Nothing attributed in this window yet.")
                    .font(Theme.entity(12))
                    .foregroundStyle(Theme.inkFaint)
                    .padding(BatteryColumn.inset)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { row in
                        BatteryRow(
                            row: row,
                            maxJoules: maxJoules,
                            expanded: expanded.contains(row.id)
                        ) {
                            if expanded.contains(row.id) { expanded.remove(row.id) } else { expanded.insert(row.id) }
                        }
                        Hairline()
                    }
                }
            }
        }
    }

    private var columnHeader: some View {
        HStack(spacing: BatteryColumn.gutter) {
            Eyebrow("Name").frame(maxWidth: .infinity, alignment: .leading)
            Eyebrow("Energy").frame(width: BatteryColumn.energy, alignment: .leading)
            HStack(spacing: 3) {
                Eyebrow("Battery")
                Text("%").font(.system(size: 9, weight: .medium)).foregroundStyle(Theme.inkFaint.opacity(0.8))
            }
            .frame(width: BatteryColumn.battery, alignment: .trailing)
            HStack(spacing: 3) {
                Eyebrow("Share")
                Text("%").font(.system(size: 9, weight: .medium)).foregroundStyle(Theme.inkFaint.opacity(0.8))
            }
            .frame(width: BatteryColumn.share, alignment: .trailing)
            Eyebrow("Confidence").frame(width: BatteryColumn.confidence, alignment: .leading)
        }
        .padding(.horizontal, BatteryColumn.inset)
        .padding(.vertical, 7)
    }

    private func emptyState(title: String, message: String, retry: Bool = false) -> some View {
        VStack(spacing: 10) {
            Text(title)
                .font(Theme.entity(15, weight: .semibold))
                .foregroundStyle(Theme.ink)
            Text(message)
                .font(Theme.entity(12))
                .foregroundStyle(Theme.inkDim)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            if retry {
                Button("Try again") {
                    Task { await model.loadBatteryHistory(range: range) }
                }
                .buttonStyle(ProminentButtonStyle())
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

// MARK: - Components

private struct StatReadout: View {
    let label: String
    let value: String
    let unit: String?
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Eyebrow(label)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(Theme.figure(22, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                if let unit {
                    Text(unit)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.inkFaint)
                }
            }
            Text(detail)
                .font(Theme.entity(10.5))
                .foregroundStyle(Theme.inkFaint)
                .lineLimit(1)
        }
        .padding(.horizontal, BatteryColumn.inset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label) \(value), \(detail)")
    }
}

private struct BatteryRow: View {
    let row: BatteryAttributionRow
    let maxJoules: Double
    let expanded: Bool
    let toggle: () -> Void
    @State private var hovering = false

    /// Unattributed energy is real but ownerless — it stays neutral so it can
    /// never read as one more app in the list.
    private var tint: Color {
        row.category == .unattributed ? Theme.inkFaint : Theme.channel(for: row.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: BatteryColumn.gutter) {
                    HStack(spacing: 9) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                            .foregroundStyle(hovering || expanded ? Theme.inkDim : Theme.inkFaint.opacity(0.55))
                            .frame(width: 9)
                        Text(row.displayName)
                            .font(Theme.entity(13, weight: .medium))
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .leading, spacing: 4) {
                        EnergyBar(
                            measured: row.measuredJoules,
                            estimated: row.heuristicJoules,
                            scale: maxJoules,
                            tint: tint
                        )
                        Text(Format.wattHours(row.totalJoules))
                            .font(Theme.figure(10))
                            .monospacedDigit()
                            .foregroundStyle(Theme.inkFaint)
                    }
                    .frame(width: BatteryColumn.energy, alignment: .leading)

                    Text(Format.percent(row.batteryPercent))
                        .font(Theme.figure(12, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(Theme.ink)
                        .frame(width: BatteryColumn.battery, alignment: .trailing)
                    Text(String(format: "%.0f", row.shareOfDrain * 100))
                        .font(Theme.figure(12))
                        .monospacedDigit()
                        .foregroundStyle(Theme.inkDim)
                        .frame(width: BatteryColumn.share, alignment: .trailing)
                    ConfidenceBadge(confidence: row.confidence)
                        .frame(width: BatteryColumn.confidence, alignment: .leading)
                }
                .padding(.horizontal, BatteryColumn.inset)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(hovering ? Theme.hover : .clear)
            .onHover { hovering = $0 }

            if expanded {
                HStack(alignment: .top, spacing: 22) {
                    Detail(label: "Foreground", value: Format.wattHours(row.foregroundJoules))
                    Detail(label: "Background", value: Format.wattHours(row.backgroundJoules))
                    Detail(label: "Active", value: Format.duration(row.activeDurationSeconds))
                    Detail(label: "Avg / peak", value: "\(Format.wattsPrecise(row.averageWatts)) / \(Format.wattsPrecise(row.peakWatts)) W")
                    Detail(label: "How we know", value: row.dominantCause)
                    Spacer()
                }
                .padding(.horizontal, BatteryColumn.inset + 18)
                .padding(.bottom, 12)
            }
        }
    }
}

private struct Detail: View {
    let label: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Eyebrow(label)
            Text(value)
                .font(Theme.entity(11))
                .foregroundStyle(Theme.inkDim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 180, alignment: .leading)
    }
}
