import AppKit
import SwiftUI

struct BrowserStartPageView: View {
    let rootPath: String?
    let onSelect: (LocalServer) -> Void

    @State private var servers: [LocalServer] = []
    @State private var liveness: [Int: Bool] = [:]
    @State private var hasScanned = false
    @State private var keyHandler = StartPageKeyHandler()
    /// Shown only when a scan outlasts a short grace period, so a fast scan
    /// never flashes a loading row (MOT-5).
    @State private var showsScanningState = false

    var body: some View {
        VStack(alignment: .leading, spacing: LiquidGlassMetrics.Spacing.medium) {
            Spacer(minLength: 0)
            if hasScanned {
                if servers.isEmpty {
                    emptyState
                        .padding(LiquidGlassMetrics.Spacing.large)
                        .transition(.opacity)
                } else {
                    serverList
                        .transition(.opacity)
                }
            } else if showsScanningState {
                scanningState
                    .padding(LiquidGlassMetrics.Spacing.large)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .animation(LiquidGlassMetrics.spring, value: hasScanned)
        .animation(LiquidGlassMetrics.spring, value: servers)
        .animation(LiquidGlassMetrics.stateChange, value: showsScanningState)
        .task(id: rootPath ?? "") { await refresh() }
        .task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            showsScanningState = true
        }
        .onAppear { syncKeyHandler() }
        .onChange(of: servers) { syncKeyHandler() }
        .onDisappear { keyHandler.remove() }
    }

    private func syncKeyHandler() {
        let snapshot = servers
        keyHandler.onDigit = { digit in
            guard digit >= 1, digit <= snapshot.count else { return false }
            onSelect(snapshot[digit - 1])
            return true
        }
        keyHandler.install()
    }

    private var sectionHeader: some View {
        Text("Local")
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }

    private var scanningState: some View {
        VStack(alignment: .leading, spacing: LiquidGlassMetrics.Spacing.xSmall) {
            sectionHeader
            HStack(spacing: LiquidGlassMetrics.Spacing.xSmall) {
                ProgressView()
                    .controlSize(.small)
                Text("Looking for dev servers…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Left-aligned (TYPE-1) with a leading symbol and the next step, so the
    /// empty start page explains itself instead of showing one gray line
    /// (MOT-6).
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: LiquidGlassMetrics.Spacing.xSmall) {
            sectionHeader
            HStack(alignment: .firstTextBaseline, spacing: LiquidGlassMetrics.Spacing.xSmall) {
                Image(systemName: "server.rack")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: LiquidGlassMetrics.Spacing.xxSmall) {
                    Text("No dev servers found in this workspace.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    // Secondary, not tertiary: the next step is the useful
                    // part, and tertiary text is under 2.5:1 (TYPE-3).
                    Text("Start a local server, or enter a URL in the address bar.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var serverList: some View {
        VStack(alignment: .leading, spacing: LiquidGlassMetrics.Spacing.small) {
            sectionHeader
                .padding(.horizontal, LiquidGlassMetrics.Spacing.large)
            // Scroll when the workspace has more dev servers than fit: an
            // unbounded card list's ideal height outgrows the pane and
            // pushes the whole pane layout down. The ScrollView spans the
            // full pane width with the padding inside it, so the overlay
            // scroll indicator at the edge never covers card content.
            ScrollView {
                VStack(spacing: LiquidGlassMetrics.Spacing.small) {
                    ForEach(Array(servers.enumerated()), id: \.element.id) { index, server in
                        LocalServerCard(
                            hotkey: index < 9 ? index + 1 : nil,
                            server: server,
                            isLive: liveness[server.port] ?? false,
                            onTap: { onSelect(server) }
                        )
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, LiquidGlassMetrics.Spacing.large)
                .padding(.bottom, LiquidGlassMetrics.Spacing.large)
            }
        }
    }

    private func refresh() async {
        let path = rootPath ?? ""
        let discovered = await LocalServerScanner.scan(rootPath: path)
        servers = discovered
        hasScanned = true
        await LocalServerLivenessMonitor.monitor(servers: discovered) { latest in
            // The monitor re-probes every couple of seconds; only touch state
            // when a port actually flips so a stable server list doesn't
            // re-render the start page (and re-layout the pane) forever.
            if latest != liveness { liveness = latest }
        }
    }
}

private struct LocalServerCard: View {
    let hotkey: Int?
    let server: LocalServer
    let isLive: Bool
    let onTap: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    /// Content card, not a control: a quiet semantic fill, no glass (glass is
    /// for the control layer) and no border (LAY-2).
    private static let cornerRadius = LiquidGlassMetrics.Radius.card
    private static let padding = LiquidGlassMetrics.Spacing.small

    var body: some View {
        Button(action: onTap) {
            // A narrow pane drops the decorative preview instead of letting
            // the card's minimum width overflow the pane, which clipped the
            // "Local" header and the cards' leading edge (LAY-6). Narrower
            // still, the hotkey badge goes too, so the URL keeps its port.
            ViewThatFits(in: .horizontal) {
                cardContent(showsThumbnail: true, showsHotkey: true)
                cardContent(showsThumbnail: false, showsHotkey: true)
                cardContent(showsThumbnail: false, showsHotkey: false)
            }
            .padding(Self.padding)
            .background(
                // `.quinary` is 253 on 255 in light mode, too faint to show
                // the tap target; one step up reads as a card (BTN-5).
                colorScheme == .light ? AnyShapeStyle(.fill.quaternary) : AnyShapeStyle(.fill.quinary),
                in: RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
            )
        }
        // Whole-card tap target: hover wash plus press dim/scale (BTN-5).
        .buttonStyle(.liquidGlassPressable(cornerRadius: Self.cornerRadius))
    }

    private func cardContent(showsThumbnail: Bool, showsHotkey: Bool) -> some View {
        HStack(spacing: LiquidGlassMetrics.Spacing.medium) {
            if showsThumbnail {
                BrowserPreviewThumbnail(
                    name: server.name,
                    displayURL: server.displayURL,
                    // Concentric with the card: outer = inner + padding (LAY-4).
                    cornerRadius: LiquidGlassMetrics.Radius.inner(
                        outer: Self.cornerRadius,
                        padding: Self.padding
                    )
                )
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(server.name)
                    .scaledFont(size: 15, weight: .semibold)
                    .lineLimit(1)
                // Truncate from the front: "…host:5173" keeps the port, which
                // is what tells two local servers apart.
                Text(server.displayURL)
                    .scaledFont(size: 13)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 0)
            if showsHotkey, let hotkey {
                Text("\(hotkey)")
                    .scaledFont(size: 12, weight: .semibold, design: .monospaced)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 20, minHeight: 20)
                    .padding(.horizontal, LiquidGlassMetrics.Spacing.xxSmall)
                    .background(
                        .fill.tertiary,
                        in: RoundedRectangle(
                            cornerRadius: LiquidGlassMetrics.Radius.control,
                            style: .continuous
                        )
                    )
            }
            Circle()
                .fill(isLive ? .green : Color(nsColor: .tertiaryLabelColor))
                .frame(width: 8, height: 8)
                .animation(LiquidGlassMetrics.stateChange, value: isLive)
        }
    }
}

/// A miniature page preview. It uses the text background color rather than
/// hard-coded white so it follows dark mode instead of glaring (COL-2).
private struct BrowserPreviewThumbnail: View {
    let name: String
    let displayURL: String
    let cornerRadius: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: LiquidGlassMetrics.Spacing.xxSmall) {
            HStack(spacing: LiquidGlassMetrics.Spacing.xxSmall) {
                Circle().fill(.red).frame(width: 5, height: 5)
                Circle().fill(.yellow).frame(width: 5, height: 5)
                Circle().fill(.green).frame(width: 5, height: 5)
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: LiquidGlassMetrics.Spacing.xxSmall) {
                Capsule().fill(Color.secondary.opacity(0.35)).frame(height: 3)
                Capsule().fill(Color.secondary.opacity(0.25)).frame(width: 38, height: 3)
            }
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .scaledFont(size: 8, weight: .semibold)
                    .lineLimit(1)
                Text(displayURL)
                    .scaledFont(size: 6.5)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(LiquidGlassMetrics.Spacing.xSmall)
        .frame(width: 96, height: 60)
        .background(
            Color(nsColor: .textBackgroundColor),
            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        )
        .foregroundStyle(.primary)
        .accessibilityHidden(true)
    }
}

// StartPageKeyHandler — installs an `NSEvent` local key-down monitor while
// the start page is on screen and forwards 1-9 keypresses to the matching
// server card. Skipped while a text editor (address bar, terminal field
// editor) is the first responder so typing isn't hijacked.
//
// AppKit's `addLocalMonitorForEvents` always invokes the handler on the
// main thread, so the `@unchecked Sendable` annotation is safe — we just
// avoid wrapping the class in `@MainActor` so the closure doesn't try to
// cross isolation with a non-Sendable `NSEvent`.
final class StartPageKeyHandler: @unchecked Sendable {
    /// Returns `true` if the digit was consumed (start page navigated). When
    /// `false`, the event is passed through so default handling fires (e.g.
    /// system beep for an unbound key).
    var onDigit: ((Int) -> Bool)?
    private var monitor: Any?

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }

    func remove() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        if let responder = NSApp.keyWindow?.firstResponder, Self.isTextEditor(responder) {
            return event
        }
        let blockedModifiers: NSEvent.ModifierFlags = [.command, .control, .option]
        guard event.modifierFlags.intersection(blockedModifiers).isEmpty,
              let digit = Self.digit(for: event) else { return event }

        let handled = onDigit?(digit) ?? false
        return handled ? nil : event
    }

    /// Maps a `keyDown` event to a 1...9 digit. Uses hardware `keyCode`
    /// first so layout/IME quirks (AZERTY top row, Dvorak, etc.) don't
    /// break the shortcut, then falls back to the character value to
    /// cover the numeric keypad.
    private static func digit(for event: NSEvent) -> Int? {
        // kVK_ANSI_1...9 keycodes in digit order. 5 and 6 are swapped
        // on the hardware (kVK_ANSI_5 = 23, kVK_ANSI_6 = 22).
        let digitRowKeyCodes: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
        if let index = digitRowKeyCodes.firstIndex(of: event.keyCode) {
            return index + 1
        }
        if let chars = event.charactersIgnoringModifiers,
           chars.count == 1,
           let digit = chars.first?.wholeNumberValue,
           (1...9).contains(digit) {
            return digit
        }
        return nil
    }

    /// Only treats *actual* text-input responders as "editors". The earlier
    /// `className.contains("Text")` heuristic was too eager — SwiftUI and
    /// AppKit ship plenty of internal responder classes with "Text" in the
    /// name (text input contexts, toolbar item hosts, layout managers) that
    /// can land as `firstResponder` even when nothing is actually being
    /// typed into, which made every digit key fall through to default
    /// handling.
    private static func isTextEditor(_ responder: NSResponder) -> Bool {
        // NSText is the abstract base of NSTextView; an NSTextField's field
        // editor is an NSTextView, so this covers SwiftUI TextField focus.
        if responder is NSText { return true }
        // Ghostty's terminal view implements NSTextInputClient — keys typed
        // into it should reach the terminal, not the start page.
        if String(describing: type(of: responder)).contains("Ghostty") { return true }
        return false
    }
}
