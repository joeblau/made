import Foundation

/// Synchronous UI reads return a recent snapshot and schedule at most one
/// asynchronous refresh per session. A wedged tmux server cannot block view
/// rendering, directory tracking, or the main actor's activity gauge.
final class TerminalRuntimeCache<Value: Sendable>: @unchecked Sendable {
    private struct Entry {
        var value: Value?
        var completedAt: TimeInterval?
        var requestID: UUID?
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private let load: @Sendable (String) async -> Value?
    private let clock: @Sendable () -> TimeInterval

    init(clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         load: @escaping @Sendable (String) async -> Value?) {
        self.clock = clock
        self.load = load
    }

    func snapshot(for session: String) -> Value? {
        let now = clock()
        let (value, request): (Value?, UUID?) = lock.withLock {
            var entry = entries[session] ?? Entry()
            let age = entry.completedAt.map { now - $0 } ?? .infinity
            let value = age <= 3 ? entry.value : nil
            guard entry.requestID == nil, age >= 1 else { return (value, nil) }
            let request = UUID()
            entry.requestID = request
            if entries.count >= 512, entries[session] == nil, let oldest = entries.keys.first {
                entries.removeValue(forKey: oldest)
            }
            entries[session] = entry
            return (value, request)
        }
        if let request {
            Task { [self] in
                let refreshed = await load(session)
                let finishedAt = clock()
                lock.withLock {
                    guard entries[session]?.requestID == request else { return }
                    entries[session] = Entry(value: refreshed, completedAt: finishedAt)
                }
            }
        }
        return value
    }

    func invalidate(_ session: String) {
        lock.withLock { _ = entries.removeValue(forKey: session) }
    }
}
