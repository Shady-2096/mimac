import SwiftUI

struct RootView: View {
    enum Section: String, CaseIterable {
        case live = "Live"
        case battery = "Battery"
    }

    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var model: LiveViewModel
    @State private var section: Section = .live
    /// scenePhase stays .active for a window that is covered or on another Space,
    /// which kept the collector in its 2-second "visible" mode all day.
    @State private var windowOnScreen = true

    var body: some View {
        ZStack {
            InstrumentBackdrop()
            VStack(spacing: 0) {
                chrome
                Hairline()
                switch section {
                case .live: LiveView()
                case .battery: BatteryHistoryView()
                }
            }
        }
        .background(WindowOcclusionReader { windowOnScreen = $0 })
        .onChange(of: section) { _, value in updateVisibility(value) }
        .onChange(of: scenePhase) { _, _ in updateVisibility(section) }
        .onChange(of: windowOnScreen) { _, _ in updateVisibility(section) }
    }

    /// One title bar shared by every screen. Leading padding keeps the wordmark
    /// clear of the window traffic lights under the hidden title bar.
    private var chrome: some View {
        HStack(spacing: 20) {
            Text("Mimac")
                .font(Theme.entity(14, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .padding(.leading, 78)

            Hairline(axis: .vertical).frame(height: 18)

            HStack(spacing: 0) {
                ForEach(Array(Section.allCases.enumerated()), id: \.element) { index, item in
                    let selected = section == item
                    Button { section = item } label: {
                        Text(item.rawValue.uppercased())
                            .font(.system(size: 9.5, weight: .semibold))
                            .tracking(0.85)
                            .foregroundStyle(selected ? Theme.ink : Theme.inkFaint)
                            .frame(width: 68, height: 24)
                            .background(selected ? Theme.panelRaised : Color.clear)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    if index < Section.allCases.count - 1 {
                        Hairline(axis: .vertical).frame(height: 24)
                    }
                }
            }
            .fixedSize()
            .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))

            Spacer()

            HStack(spacing: 7) {
                StatusDot(color: statusColor)
                Text(model.connectionState.label)
                    .font(Theme.entity(11, weight: .medium))
                    .foregroundStyle(Theme.inkDim)
                if let timestamp = model.snapshot?.timestamp, model.connectionState == .live {
                    Text(timestamp, style: .time)
                        .font(Theme.figure(11))
                        .monospacedDigit()
                        .foregroundStyle(Theme.inkFaint)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Collector \(model.connectionState.label)")
        }
        .padding(.trailing, 20)
        .frame(height: 46)
    }

    private var statusColor: Color {
        switch model.connectionState {
        case .live: return Theme.nominal
        case .connecting: return Theme.caution
        case .unavailable: return Theme.alarm
        }
    }

    private func updateVisibility(_ value: Section) {
        let onScreen = scenePhase == .active && windowOnScreen
        model.setWindowOnScreen(onScreen)
        model.setLiveVisible(value == .live && onScreen)
    }
}

/// Reports whether the hosting window has any part on screen: false when it is
/// minimized, fully covered, or on another Space.
private struct WindowOcclusionReader: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> ObservingView {
        ObservingView(onChange: onChange)
    }

    func updateNSView(_ view: ObservingView, context: Context) {
        view.onChange = onChange
    }

    final class ObservingView: NSView {
        var onChange: (Bool) -> Void
        private var observer: NSObjectProtocol?

        init(onChange: @escaping (Bool) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard let window else { return }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                guard let self, let window = self.window else { return }
                self.onChange(window.occlusionState.contains(.visible))
            }
            onChange(window.occlusionState.contains(.visible))
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
}
