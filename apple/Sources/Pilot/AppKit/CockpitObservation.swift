import Foundation
import Observation

/// Re-arms Observation after a model change and releases UI work when hidden.
/// The generation fence makes callbacks from an earlier attachment harmless.
@MainActor
final class CockpitObservation {
    private var update: @MainActor () -> Void
    private var generation: UInt64 = 0
    private var isActive = false

    init(_ update: @escaping @MainActor () -> Void) {
        self.update = update
    }

    convenience init<Owner: AnyObject>(
        owner: Owner,
        update: @escaping @MainActor (Owner) -> Void
    ) {
        self.init { [weak owner] in
            if let owner { update(owner) }
        }
    }

    func start() {
        guard !isActive else { return }
        isActive = true
        refresh()
    }

    func stop() {
        isActive = false
        generation &+= 1
    }

    func refresh() {
        generation &+= 1
        guard isActive else {
            update()
            return
        }
        let current = generation
        withObservationTracking {
            update()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isActive, self.generation == current else { return }
                self.refresh()
            }
        }
    }
}
