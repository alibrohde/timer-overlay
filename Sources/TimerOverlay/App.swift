import SwiftUI
import AppKit
import Combine

// State file written by Raycast extensions.
// Bar reads this once a second to detect new/stopped timers.
struct TimerState: Codable, Equatable {
    let label: String?
    let started_at: Date
    let end_time: Date
}

@MainActor
final class TimerStore: ObservableObject {
    @Published var state: TimerState?
    @Published var now: Date = Date()

    private let stateURL: URL
    private var pollTimer: Timer?
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
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

    var remainingSeconds: Int? {
        guard let s = state else { return nil }
        let r = Int(s.end_time.timeIntervalSince(now).rounded(.up))
        return r > 0 ? r : nil
    }
}

struct BarView: View {
    @ObservedObject var store: TimerStore

    var body: some View {
        HStack(spacing: 10) {
            Text(formattedTime)
                .font(.system(size: 13, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 5))
            if let label = store.state?.label, !label.isEmpty {
                Text(label).font(.system(size: 14))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.secondary.opacity(0.15), lineWidth: 0.5))
        .fixedSize()
    }

    private var formattedTime: String {
        let s = store.remainingSeconds ?? 0
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

        cancellable = store.$state
            .map { $0 != nil }
            .removeDuplicates()
            .sink { [weak self] hasState in
                Task { @MainActor in self?.updateVisibility(hasState: hasState) }
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

    private func setupPanel() {
        let host = NSHostingController(rootView: BarView(store: store))
        host.sizingOptions = .preferredContentSize

        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 44),
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
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false

        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            let panelSize = panel.frame.size
            let x = frame.midX - panelSize.width / 2
            let y = frame.maxY - panelSize.height - 50
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }
    }

    private func updateVisibility(hasState: Bool) {
        if hasState {
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
        }
    }

    @objc private func showBar() { panel.orderFrontRegardless() }
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
