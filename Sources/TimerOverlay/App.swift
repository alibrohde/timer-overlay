import SwiftUI
import AppKit
import Combine

// State file written by Raycast extensions.
// Countdown: end_time set. Stopwatch: end_time nil → counts up from started_at.
struct TimerState: Codable, Equatable {
    let label: String?
    let started_at: Date
    let end_time: Date?
    let minutes: Int?
    let active_state_file: String?
    let log_file_path: String?
    let alert_volume: Double?
}

@MainActor
final class TimerStore: ObservableObject {
    @Published var state: TimerState?
    @Published var now: Date = Date()

    private let stateURL: URL
    private var pollTimer: Timer?
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        // JS Date.toISOString() emits ".NNNZ" (fractional seconds); Swift's built-in
        // .iso8601 rejects that. Try both fractional and plain ISO8601 forms.
        d.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let str = try container.decode(String.self)
            let withFrac = ISO8601DateFormatter()
            withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let noFrac = ISO8601DateFormatter()
            noFrac.formatOptions = [.withInternetDateTime]
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

    func reloadFromDisk() {
        reload()
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
    private let accent = Color(red: 1.0, green: 0.16, blue: 0.52)

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
        .foregroundStyle(accent)
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.black.opacity(0.86), in: Capsule())
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

final class DraggableOverlayPanel: NSPanel {
    var onMoveEnded: ((NSPoint) -> Void)?
    private var dragStartMouse: NSPoint?
    private var dragStartOrigin: NSPoint?

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            beginDrag()
        case .leftMouseDragged:
            updateDrag()
        case .leftMouseUp:
            endDrag()
        default:
            break
        }
        super.sendEvent(event)
    }

    private func beginDrag() {
        dragStartMouse = NSEvent.mouseLocation
        dragStartOrigin = frame.origin
    }

    private func updateDrag() {
        guard let startMouse = dragStartMouse, let startOrigin = dragStartOrigin else { return }
        let mouse = NSEvent.mouseLocation
        let next = NSPoint(
            x: startOrigin.x + mouse.x - startMouse.x,
            y: startOrigin.y + mouse.y - startMouse.y
        )
        setFrameOrigin(clampedPosition(next))
    }

    private func endDrag() {
        onMoveEnded?(frame.origin)
        dragStartMouse = nil
        dragStartOrigin = nil
    }

    private func clampedPosition(_ point: NSPoint) -> NSPoint {
        let nextFrame = NSRect(origin: point, size: frame.size)
        guard let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(nextFrame) })
                ?? NSScreen.main
        else { return point }

        let screenFrame = screen.visibleFrame
        let maxX = screenFrame.maxX - frame.width
        let maxY = screenFrame.maxY - frame.height
        let x = min(max(point.x, screenFrame.minX), maxX)
        let y = min(max(point.y, screenFrame.minY), maxY)
        return NSPoint(x: x, y: y)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var panel: DraggableOverlayPanel!
    private var store: TimerStore!
    private var cancellable: AnyCancellable?

    // Tracks the previous tick so we can detect natural countdown expiration
    // (countdown active → not visible AND the prior end_time has passed) vs a
    // user-initiated stop (state vanished while end_time was still in the future).
    private var lastCountdownEndTime: Date?
    private var lastWasVisibleCountdown = false
    private var alertedEndTime: Date?
    private var preferencesURL: URL {
        URL(fileURLWithPath: NSString(string: "~/.timer-overlay/preferences.json").expandingTildeInPath)
    }

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
        updateVisibility(visible: store.displaySeconds != nil)

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
           prevEnd <= now,
           alertedEndTime != prevEnd
        {
            alertedEndTime = prevEnd
            handleExpiredTimer()
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
        menu.addItem(NSMenuItem(title: "Reset position", action: #selector(resetPosition), keyEquivalent: ""))
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
            rootView: BarView(
                store: store,
                width: Self.panelWidth,
                height: Self.panelHeight
            )
        )

        panel = DraggableOverlayPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: Self.panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = host
        panel.level = .screenSaver
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .fullScreenAuxiliary,
            .ignoresCycle
        ]
        panel.onMoveEnded = { [weak self] point in
            Task { @MainActor in self?.savePosition(point) }
        }
        panel.ignoresMouseEvents = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false  // shadow on a borderless transparent panel paints the full rect; skip it
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false

        positionAtSavedOrDefault()
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

    private func positionAtSavedOrDefault() {
        if let saved = savedPosition() {
            panel.setFrameOrigin(clampedPosition(saved))
        } else {
            positionAtBottomCenter()
        }
    }

    private func savedPosition() -> NSPoint? {
        guard let data = try? Data(contentsOf: preferencesURL),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let x = payload["x"] as? Double,
              let y = payload["y"] as? Double
        else { return nil }
        return NSPoint(x: x, y: y)
    }

    private func savePosition(_ point: NSPoint) {
        try? FileManager.default.createDirectory(
            at: preferencesURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let payload: [String: Any] = ["x": point.x, "y": point.y]
        writeJSON(payload, to: preferencesURL)
    }

    private func clampedPosition(_ point: NSPoint) -> NSPoint {
        guard let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(panel.frame) })
                ?? NSScreen.main
        else { return point }

        let frame = screen.visibleFrame
        let x = min(max(point.x, frame.minX), frame.maxX - Self.panelWidth)
        let y = min(max(point.y, frame.minY), frame.maxY - Self.panelHeight)
        return NSPoint(x: x, y: y)
    }

    private func updateVisibility(visible: Bool) {
        if visible {
            positionAtSavedOrDefault()
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
        }
    }

    @objc private func showBar() {
        positionAtSavedOrDefault()
        panel.orderFrontRegardless()
    }
    @objc private func hideBar() { panel.orderOut(nil) }
    @objc private func resetPosition() {
        try? FileManager.default.removeItem(at: preferencesURL)
        positionAtBottomCenter()
        savePosition(panel.frame.origin)
    }

    private func handleExpiredTimer() {
        guard let expired = store.state else { return }

        let alertToken = startNoisyAlert(label: expired.label, volume: expired.alert_volume ?? 7)
        let extensionMinutes = askForExtension(expired)
        stopNoisyAlert(alertToken)

        if let extensionMinutes {
            extend(expired, by: extensionMinutes)
            return
        }

        appendLog("Completed \(expired.minutes ?? estimatedMinutes(expired)) min timer\(labelSuffix(expired.label))", to: expired.log_file_path)
        clear(expired)
    }

    private func startNoisyAlert(label: String?, volume: Double) -> URL {
        let token = FileManager.default.temporaryDirectory
            .appendingPathComponent("timer-overlay-alert-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: token.path, contents: Data())

        let safeVolume = min(max(volume, 0.1), 10)
        let spoken = label.map { "Timer done. \($0)." } ?? "Timer done."
        let command = """
        while [ -f \(shellQuoted(token.path)) ]; do
          afplay --volume \(safeVolume) /System/Library/Sounds/Sosumi.aiff &
          afplay --volume \(safeVolume) /System/Library/Sounds/Basso.aiff &
          say \(shellQuoted(spoken)) &
          sleep 3
        done
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        try? process.run()
        return token
    }

    private func stopNoisyAlert(_ token: URL) {
        try? FileManager.default.removeItem(at: token)
    }

    private func askForExtension(_ timer: TimerState) -> Int? {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Timer done"
        alert.informativeText = timer.label.map {
            "\(timer.minutes ?? estimatedMinutes(timer)) min timer: \($0)\n\nExtend it?"
        } ?? "\(timer.minutes ?? estimatedMinutes(timer)) min timer\n\nExtend it?"
        alert.addButton(withTitle: "Extend 5 min")
        alert.addButton(withTitle: "Extend 10 min")
        alert.addButton(withTitle: "Done")
        alert.alertStyle = .informational

        let result = alert.runModal()
        if result == .alertFirstButtonReturn { return 5 }
        if result == .alertSecondButtonReturn { return 10 }
        return nil
    }

    private func extend(_ timer: TimerState, by minutes: Int) {
        let now = Date()
        let end = now.addingTimeInterval(TimeInterval(minutes * 60))
        let next = TimerState(
            label: timer.label,
            started_at: now,
            end_time: end,
            minutes: minutes,
            active_state_file: timer.active_state_file,
            log_file_path: timer.log_file_path,
            alert_volume: timer.alert_volume
        )

        writeOverlay(next)
        writeActiveState(next)
        appendLog("Extended timer by \(minutes) min\(labelSuffix(timer.label))", to: timer.log_file_path)
        alertedEndTime = nil
        store.reloadFromDisk()
    }

    private func clear(_ timer: TimerState) {
        if let active = timer.active_state_file {
            try? FileManager.default.removeItem(atPath: NSString(string: active).expandingTildeInPath)
        }
        let overlay = NSString(string: "~/.timer-overlay/state.json").expandingTildeInPath
        try? FileManager.default.removeItem(atPath: overlay)
        store.reloadFromDisk()
    }

    private func writeOverlay(_ timer: TimerState) {
        let overlayURL = URL(fileURLWithPath: NSString(string: "~/.timer-overlay/state.json").expandingTildeInPath)
        try? FileManager.default.createDirectory(
            at: overlayURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let payload: [String: Any] = [
            "label": jsonValue(timer.label),
            "started_at": isoString(timer.started_at),
            "end_time": jsonValue(timer.end_time.map(isoString)),
            "minutes": jsonValue(timer.minutes),
            "active_state_file": jsonValue(timer.active_state_file),
            "log_file_path": jsonValue(timer.log_file_path),
            "alert_volume": jsonValue(timer.alert_volume)
        ]
        writeJSON(payload, to: overlayURL)
    }

    private func writeActiveState(_ timer: TimerState) {
        guard let active = timer.active_state_file, let end = timer.end_time else { return }
        let url = URL(fileURLWithPath: NSString(string: active).expandingTildeInPath)
        let payload: [String: Any] = [
            "startTime": isoString(timer.started_at),
            "minutes": timer.minutes ?? estimatedMinutes(timer),
            "endTime": isoString(end),
            "label": jsonValue(timer.label)
        ]
        writeJSON(payload, to: url)
    }

    private func jsonValue<T>(_ value: T?) -> Any {
        value ?? NSNull()
    }

    private func writeJSON(_ payload: [String: Any], to url: URL) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])
        else { return }
        try? data.write(to: url)
    }

    private func appendLog(_ event: String, to path: String?) {
        guard let rawPath = path, !rawPath.isEmpty else { return }
        let url = URL(fileURLWithPath: NSString(string: rawPath).expandingTildeInPath)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let now = Date()
        let dateHeading = "## \(dateString(now))"
        let entry = "- \(timeString(now)) — \(event)"
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let next: String

        if let headingRange = existing.range(of: dateHeading) {
            let afterHeading = headingRange.upperBound
            let nextHeading = existing[afterHeading...].range(of: "\n## ")
            let insertAt = nextHeading?.lowerBound ?? existing.endIndex
            next = existing[..<insertAt].trimmingCharacters(in: .whitespacesAndNewlines)
                + "\n" + entry + "\n" + existing[insertAt...]
        } else {
            next = existing.trimmingCharacters(in: .whitespacesAndNewlines)
                + (existing.isEmpty ? "" : "\n\n")
                + dateHeading + "\n\n" + entry + "\n"
        }

        try? next.write(to: url, atomically: true, encoding: .utf8)
    }

    private func estimatedMinutes(_ timer: TimerState) -> Int {
        guard let end = timer.end_time else { return 0 }
        return max(1, Int((end.timeIntervalSince(timer.started_at) / 60).rounded()))
    }

    private func labelSuffix(_ label: String?) -> String {
        guard let label, !label.isEmpty else { return "" }
        return ": \(label)"
    }

    private func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func dateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func timeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: date)
    }
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
