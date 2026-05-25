import SwiftUI
import AppKit
import Combine

// State file written by Raycast extensions.
// Countdown: end_time set. Stopwatch: end_time nil → counts up from started_at.
struct TimerState: Codable, Equatable {
    let label: String?
    let started_at: Date
    let end_time: Date?
}

@MainActor
final class TimerStore: ObservableObject {
    @Published var state: TimerState?
    @Published var now: Date = Date()

    private let stateURL: URL
    private var pollTimer: Timer?
    private let decoder: JSONDecoder = {
        let withFrac = ISO8601DateFormatter()
        withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let noFrac = ISO8601DateFormatter()
        noFrac.formatOptions = [.withInternetDateTime]
        let d = JSONDecoder()
        // JS Date.toISOString() emits ".NNNZ" (fractional seconds); Swift's built-in
        // .iso8601 rejects that. Try both fractional and plain ISO8601 forms.
        d.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let str = try container.decode(String.self)
            if let date = withFrac.date(from: str) { return date }
            if let date = noFrac.date(from: str) { return date }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid ISO8601 date: \(str)"
            )
        }
        return d
    }()

    init(stateURL: URL) { self.stateURL = stateURL }

    func start() {
        reload()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.now = Date()
                self?.reload()
            }
        }
    }

    private func reload() {
        guard let data = try? Data(contentsOf: stateURL),
              let parsed = try? decoder.decode(TimerState.self, from: data) else {
            if state != nil { state = nil }
            return
        }
        if parsed != state { state = parsed }
    }

    // Seconds to display, or nil if the bar should hide.
    // Countdown: time remaining; hides at 0.
    // Stopwatch: time elapsed since started_at; never auto-hides.
    var displaySeconds: Int? {
        guard let s = state else { return nil }
        if let end = s.end_time {
            let r = Int(end.timeIntervalSince(now).rounded(.up))
            return r > 0 ? r : nil
        }
        return max(0, Int(now.timeIntervalSince(s.started_at)))
    }
}

struct BarView: View {
    @ObservedObject var store: TimerStore
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        HStack {
            Spacer(minLength: 0)
            pill
            Spacer(minLength: 0)
        }
        .frame(width: width, height: height)
    }

    private var pill: some View {
        HStack(spacing: 12) {
            Text(formattedTime)
                .font(.system(size: 30, weight: .semibold, design: .monospaced))
                .monospacedDigit()
            if let label = store.state?.label, !label.isEmpty {
                Text(label)
                    .font(.system(size: 26, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.8), radius: 4, x: 0, y: 1)
        .shadow(color: .black.opacity(0.35), radius: 12, x: 0, y: 2)
    }

    private var formattedTime: String {
        let s = store.displaySeconds ?? 0
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, sec)
            : String(format: "%d:%02d", m, sec)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var panel: NSPanel!
    private var store: TimerStore!
    private var cancellable: AnyCancellable?

    // Tracks the previous tick so we can detect natural countdown expiration
    // (countdown active → not visible AND the prior end_time has passed) vs a
    // user-initiated stop (state vanished while end_time was still in the future).
    private var lastCountdownEndTime: Date?
    private var lastWasVisibleCountdown = false

    func applicationDidFinishLaunching(_ note: Notification) {
        let stateURL = URL(
            fileURLWithPath: NSString(string: "~/.timer-overlay/state.json")
                .expandingTildeInPath
        )
        try? FileManager.default.createDirectory(
            at: stateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        store = TimerStore(stateURL: stateURL)
        setupStatusItem()
        setupPanel()
        store.start()

        cancellable = Publishers.CombineLatest(store.$state, store.$now)
            .sink { [weak self] _, _ in
                Task { @MainActor in self?.onTick() }
            }
    }

    private func onTick() {
        let visible = store.displaySeconds != nil
        let state = store.state
        let now = store.now

        // Detect natural countdown expiration: previous tick had a visible
        // countdown, current tick is hidden, and that countdown's end_time
        // is now in the past. Only fire if it's a genuine expiry, not a user stop.
        if lastWasVisibleCountdown && !visible,
           let prevEnd = lastCountdownEndTime,
           prevEnd <= now
        {
            NSSound(named: "Glass")?.play()
        }

        lastCountdownEndTime = state?.end_time
        lastWasVisibleCountdown = visible && state?.end_time != nil

        if panel.isVisible != visible {
            updateVisibility(visible: visible)
        }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "⏱"

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Show bar", action: #selector(showBar), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Hide bar", action: #selector(hideBar), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(
            title: "Quit",
            action: #selector(NSApp.terminate(_:)),
            keyEquivalent: "q"
        ))
        statusItem.menu = menu
    }

    // Fixed panel size; SwiftUI content centers itself via outer Spacers.
    // Width is generous to fit long labels; height accommodates pill + breathing room.
    private static let panelWidth: CGFloat = 520
    private static let panelHeight: CGFloat = 78

    private func setupPanel() {
        let host = NSHostingController(
            rootView: BarView(store: store, width: Self.panelWidth, height: Self.panelHeight)
        )

        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: Self.panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = host
        panel.level = .floating
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .fullScreenAuxiliary,
            .ignoresCycle
        ]
        // Pure display overlay — let clicks pass through everywhere, including the pill.
        panel.ignoresMouseEvents = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false  // shadow on a borderless transparent panel paints the full rect; skip it
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false

        positionAtBottomCenter()
    }

    // Bottom-center placement, matching Raycast Focus bar position.
    // visibleFrame.minY already excludes the dock.
    private func positionAtBottomCenter() {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let x = frame.midX - Self.panelWidth / 2
        let y = frame.minY + 16
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func updateVisibility(visible: Bool) {
        if visible {
            positionAtBottomCenter()
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
        }
    }

    @objc private func showBar() {
        positionAtBottomCenter()
        panel.orderFrontRegardless()
    }
    @objc private func hideBar() { panel.orderOut(nil) }
}

@main
struct TimerOverlayApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
