import AppKit
import SwiftUI

struct BrowserStartPageView: View {
    let rootPath: String?
    let onSelect: (LocalServer) -> Void

    @State private var servers: [LocalServer] = []
    @State private var liveness: [Int: Bool] = [:]
    @State private var hasScanned = false
    @State private var keyHandler = StartPageKeyHandler()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Spacer(minLength: 0)
            if hasScanned {
                if servers.isEmpty {
                    emptyState
                        .padding(20)
                } else {
                    serverList
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .task(id: rootPath ?? "") { await refresh() }
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

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Local")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("No dev servers found in this workspace.")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
    }

    private var serverList: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Local")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
            // Scroll when the workspace has more dev servers than fit: an
            // unbounded card list's ideal height outgrows the pane and
            // pushes the whole pane layout down. The ScrollView spans the
            // full pane width with the padding inside it, so the overlay
            // scroll indicator at the edge never covers card content.
            ScrollView {
                VStack(spacing: 10) {
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
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
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

    @State private var isHovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                BrowserPreviewThumbnail(name: server.name, displayURL: server.displayURL)
                VStack(alignment: .leading, spacing: 2) {
                    Text(server.name)
                        .scaledFont(size: 15, weight: .semibold)
                        .lineLimit(1)
                    Text(server.displayURL)
                        .scaledFont(size: 13)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if let hotkey {
                    Text("\(hotkey)")
                        .scaledFont(size: 12, weight: .semibold, design: .monospaced)
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 18, minHeight: 18)
                        .padding(.horizontal, 4)
                        .background {
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.6))
                        }
                }
                Circle()
                    .fill(isLive ? .green : Color(nsColor: .tertiaryLabelColor))
                    .frame(width: 8, height: 8)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(isHovering ? 0.10 : 0.06))
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

private struct BrowserPreviewThumbnail: View {
    let name: String
    let displayURL: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 3) {
                Circle().fill(.red).frame(width: 5, height: 5)
                Circle().fill(.yellow).frame(width: 5, height: 5)
                Circle().fill(.green).frame(width: 5, height: 5)
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 3) {
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
        .padding(6)
        .frame(width: 96, height: 60)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white)
        }
        .foregroundStyle(.black)
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
