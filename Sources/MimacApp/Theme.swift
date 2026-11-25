import AppKit
import SwiftUI
import MimacIdentity

// MARK: - Adaptive color primitives

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }

    init(light: Color, dark: Color) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(dark) : NSColor(light)
        })
    }
}

// MARK: - Design tokens
//
// See DESIGN.md. The surface is a quiet measuring instrument: a warm-neutral
// graphite chassis, recessed fields for anything plotted, hairlines instead of
// shadows, and colour that only ever attaches to data. Designed dark-first —
// the use scene is a developer at night beside a dark editor — with a faithful
// light transposition, because forcing a scheme in a utility is hostile.

enum Theme {
    static let panel = Color(light: Color(hex: 0xF2F4F5), dark: Color(hex: 0x101315))
    static let panelRaised = Color(light: Color(hex: 0xFFFFFF), dark: Color(hex: 0x171B1E))
    static let well = Color(light: Color(hex: 0xE8ECEE), dark: Color(hex: 0x0A0C0E))
    static let hairline = Color(light: Color(hex: 0xD2D8DB), dark: Color(hex: 0x2A3135))
    static let graticule = Color(light: Color(hex: 0xDFE4E7), dark: Color(hex: 0x20272B))
    static let hover = Color(light: Color(hex: 0x0A0C0E).opacity(0.04), dark: Color(hex: 0xE6EBED).opacity(0.035))

    static let ink = Color(light: Color(hex: 0x12181B), dark: Color(hex: 0xE6EBED))
    static let inkDim = Color(light: Color(hex: 0x4E585D), dark: Color(hex: 0xA8B2B7))
    static let inkFaint = Color(light: Color(hex: 0x6E797E), dark: Color(hex: 0x7C868B))

    /// Instrument conditions. Deliberately off the channel register so a
    /// condition can never be mistaken for an identity. Never used alone —
    /// every one of these is paired with a word.
    static let nominal = Color(light: Color(hex: 0x2F6B57), dark: Color(hex: 0x6FA88F))
    static let caution = Color(light: Color(hex: 0x8A6015), dark: Color(hex: 0xE2A03F))
    static let alarm = Color(light: Color(hex: 0xA83A2E), dark: Color(hex: 0xE05C4E))

    /// Channel identity, in the canonical scope order. A channel colour marks
    /// *an entity*, not a severity, and is assigned by a stable hash of the
    /// entity id so a row keeps its colour as the ranking churns.
    static let channels: [Color] = [
        Color(light: Color(hex: 0xA87A0E), dark: Color(hex: 0xE8B93C)),
        Color(light: Color(hex: 0x17798E), dark: Color(hex: 0x4FC3D9)),
        Color(light: Color(hex: 0xA83C77), dark: Color(hex: 0xD96BA8)),
        Color(light: Color(hex: 0x3F7F2E), dark: Color(hex: 0x7FBF6A)),
        Color(light: Color(hex: 0x5C4CA8), dark: Color(hex: 0x9B8BD9)),
        Color(light: Color(hex: 0xA85A1E), dark: Color(hex: 0xE08A4C)),
    ]

    static func channel(for identifier: String) -> Color {
        var hash: UInt64 = 5381
        for byte in identifier.utf8 { hash = (hash &* 33) &+ UInt64(byte) }
        return channels[Int(hash % UInt64(channels.count))]
    }

    // Type. Every number is monospaced with tabular figures so columns align on
    // the decimal; legends are the only uppercase in the app and are always small.
    static func figure(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    static func entity(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
}

// MARK: - Shared building blocks

/// The chassis. Flat by design: depth in this system comes from value steps and
/// hairlines, never from a gradient or a shadow.
struct InstrumentBackdrop: View {
    var body: some View {
        Theme.panel.ignoresSafeArea().accessibilityHidden(true)
    }
}

/// A 1px rule. Regions in this app meet at rules rather than floating as cards.
struct Hairline: View {
    var axis: Axis = .horizontal
    var body: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(
                width: axis == .vertical ? 1 : nil,
                height: axis == .horizontal ? 1 : nil
            )
            .accessibilityHidden(true)
    }
}

/// A recessed field — the only place plotted marks live. One inner top edge,
/// because a recessed surface catches light on its upper bezel.
struct Well<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .background(Theme.well)
            .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
            .overlay(alignment: .top) {
                Rectangle().fill(Theme.hairline.opacity(0.6)).frame(height: 1)
            }
    }
}

/// Small tracked uppercase label. Used for column heads and rail sections only —
/// an eyebrow on every element is grammar nobody chose.
struct Eyebrow: View {
    let text: String
    var tint: Color = Theme.inkFaint
    init(_ text: String, tint: Color = Theme.inkFaint) {
        self.text = text
        self.tint = tint
    }
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 9.5, weight: .semibold))
            .tracking(0.85)
            .foregroundStyle(tint)
    }
}

/// A steady indicator. Instruments do have status lamps; they do not throb.
struct StatusDot: View {
    let color: Color
    var pulsing: Bool = false
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .accessibilityHidden(true)
    }
}

struct ConfidenceBadge: View {
    let confidence: AttributionConfidence
    var body: some View {
        Text(label.uppercased())
            .font(.system(size: 9.5, weight: .semibold))
            .tracking(0.85)
            .foregroundStyle(confidence == .high ? Theme.inkDim : color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(confidence == .high ? Color.clear : color.opacity(0.12))
            .overlay(Rectangle().stroke(confidence == .high ? Theme.hairline : color.opacity(0.35), lineWidth: 1))
            .accessibilityLabel("\(label) confidence")
    }
    private var label: String {
        switch confidence {
        case .high: return "High"
        case .medium: return "Medium"
        case .low: return "Low"
        }
    }
    private var color: Color {
        switch confidence {
        case .high: return Theme.nominal
        case .medium: return Theme.caution
        case .low: return Theme.alarm
        }
    }
}

/// The measurement-honesty mark, carried over from the previous design and
/// restated in this world's material: the measured portion is solid, the
/// estimated portion is 45° hatching — the engineering-drawing convention for an
/// inferred region, which is exactly what an estimate is. Flat, square, no glow.
struct EnergyBar: View {
    let measured: Double
    let estimated: Double
    let scale: Double
    var tint: Color = Theme.inkDim

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let safeScale = max(scale, 0.0001)
            let measuredWidth = width * min(1, measured / safeScale)
            let estimatedWidth = min(width - measuredWidth, width * min(1, estimated / safeScale))
            ZStack(alignment: .leading) {
                Rectangle().fill(Theme.hairline.opacity(0.5)).frame(height: 1).offset(y: 1)
                HStack(spacing: 0) {
                    Rectangle().fill(tint).frame(width: measuredWidth)
                    Rectangle()
                        .fill(tint.opacity(0.14))
                        .overlay(Hatching().stroke(tint.opacity(0.7), lineWidth: 1))
                        .frame(width: estimatedWidth)
                }
            }
        }
        .frame(height: 3)
        .accessibilityHidden(true)
    }
}

struct Hatching: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        var x = -rect.height
        while x < rect.width {
            path.move(to: CGPoint(x: x, y: rect.maxY))
            path.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += 3
        }
        return path
    }
}

/// A row's own recent history, in its channel colour. This is the thing Activity
/// Monitor cannot do: it keeps no past. Drawn only for entities whose draw is
/// large enough to mean something, so 200 idle rows stay quiet.
struct Sparkline: View {
    let values: [Double]
    let tint: Color
    var filled = true

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            // Headroom above the peak, so a steady reading draws as a line
            // sitting inside the field rather than pinned to its ceiling.
            let peak = max(values.max() ?? 0, 0.0001) * 1.18
            let step = values.count > 1 ? size.width / CGFloat(values.count - 1) : size.width
            let points = values.enumerated().map { index, value in
                CGPoint(
                    x: CGFloat(index) * step,
                    y: size.height - CGFloat(min(1, value / peak)) * (size.height - 1) - 0.5
                )
            }
            ZStack {
                if filled, points.count > 1 {
                    Path { path in
                        path.move(to: CGPoint(x: points[0].x, y: size.height))
                        points.forEach { path.addLine(to: $0) }
                        path.addLine(to: CGPoint(x: points[points.count - 1].x, y: size.height))
                        path.closeSubpath()
                    }
                    .fill(tint.opacity(0.16))
                }
                if points.count > 1 {
                    Path { path in
                        path.move(to: points[0])
                        points.dropFirst().forEach { path.addLine(to: $0) }
                    }
                    .stroke(tint, style: StrokeStyle(lineWidth: 1, lineJoin: .round))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// Horizontal rules behind a plotted field. Structure, not decoration — and only
/// where something is actually plotted.
struct Graticule: View {
    var divisions: Int = 4
    var body: some View {
        GeometryReader { geometry in
            let spacing = geometry.size.height / CGFloat(divisions)
            Path { path in
                for index in 1..<divisions {
                    let y = spacing * CGFloat(index)
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: geometry.size.width, y: y))
                }
            }
            .stroke(Theme.graticule, lineWidth: 1)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Buttons

struct ProminentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.entity(12, weight: .semibold))
            .foregroundStyle(Theme.panel)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Theme.ink.opacity(configuration.isPressed ? 0.78 : 0.92))
            .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
    }
}

struct SubtleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.entity(12, weight: .medium))
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(configuration.isPressed ? Theme.hover : Color.clear)
            .overlay(RoundedRectangle(cornerRadius: 2, style: .continuous).stroke(Theme.hairline, lineWidth: 1))
    }
}

/// Segmented keys. Fixed geometry so live data can never shift the selection,
/// and no sliding highlight — the switch is instant, the way a key is.
struct PillPicker<Option: Hashable>: View {
    let options: [Option]
    let title: (Option) -> String
    @Binding var selection: Option

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.element) { index, option in
                let selected = option == selection
                Button { selection = option } label: {
                    Text(title(option).uppercased())
                        .font(.system(size: 9.5, weight: .semibold))
                        .tracking(0.85)
                        .foregroundStyle(selected ? Theme.ink : Theme.inkFaint)
                        .frame(width: 56, height: 24)
                        .background(selected ? Theme.panelRaised : Color.clear)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
                if index < options.count - 1 {
                    Hairline(axis: .vertical).frame(height: 24)
                }
            }
        }
        .fixedSize()
        .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
    }
}

// MARK: - Formatting

enum Format {
    static func bytes(_ value: UInt64) -> String { scaled(Double(value)) }
    static func rate(_ value: Double) -> String { "\(scaled(value))/s" }

    private static func scaled(_ value: Double) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var scaled = value
        var index = 0
        // 999.7 rounds to "1000 MB" at zero decimals, so step up on what the
        // figure will actually print rather than on its exact value.
        while scaled >= 999.5, index < units.count - 1 {
            scaled /= 1000
            index += 1
        }
        return String(format: scaled >= 10 || index == 0 ? "%.0f %@" : "%.1f %@", scaled, units[index])
    }

    /// Memory in the units Apple labels RAM with — binary gigabytes — so a
    /// 16 GB Mac reads as "16 GB" instead of the 17.2 that decimal scaling
    /// would print.
    static func memoryGB(_ bytes: UInt64, decimals: Int = 1) -> String {
        String(format: "%.\(decimals)f GB", Double(bytes) / 1_073_741_824)
    }

    /// Bare degrees. The unit rides in the column head or beside the readout, so
    /// the figure stays a clean number that lines up with the ones above it.
    static func celsius(_ value: Double) -> String { String(format: "%.0f", value) }

    static func watts(_ value: Double) -> String { String(format: "%.1f", value) }
    static func wattsPrecise(_ value: Double) -> String { String(format: "%.2f", value) }
    static func percent(_ value: Double) -> String { String(format: "%.1f", value) }
    static func wattHours(_ joules: Double) -> String { String(format: "%.2f Wh", joules / 3600) }

    /// Adaptive energy: tiny amounts read as mWh so a table of short windows
    /// isn't a wall of "0.00 Wh".
    static func energy(_ joules: Double) -> String {
        let wattHours = joules / 3600
        if wattHours >= 0.1 { return String(format: "%.2f Wh", wattHours) }
        if wattHours >= 0.0005 { return String(format: "%.0f mWh", wattHours * 1000) }
        return "<1 mWh"
    }

    static func minutesRemaining(_ minutes: Int?) -> String {
        guard let minutes, minutes > 0 else { return "N/A" }
        if minutes < 60 { return "\(minutes) min" }
        // Above an hour the estimate is coarse by nature; 5-minute steps keep the
        // display from flickering between near-identical values.
        let rounded = (minutes + 2) / 5 * 5
        return String(format: "%d h %02d min", rounded / 60, rounded % 60)
    }

    static func duration(_ seconds: Double) -> String {
        if seconds >= 5400 { return String(format: "%.1f h", seconds / 3600) }
        if seconds >= 60 { return String(format: "%.0f min", seconds / 60) }
        return String(format: "%.0f s", seconds)
    }
}
