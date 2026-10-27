import SwiftUI

struct BuildElapsedTime: View {
    let state: BuildActivityState

    var body: some View {
        if let startedAt = state.startedAt {
            if state.isComplete {
                let elapsed = max(0, (state.finishedAt ?? state.checkedAt) - startedAt)
                Text(Duration.seconds(elapsed), format: .time(pattern: elapsed >= 3600 ? .hourMinuteSecond : .minuteSecond))
                    .monospacedDigit()
            } else {
                Text(Date(timeIntervalSince1970: startedAt), style: .timer).monospacedDigit()
            }
        } else {
            Text("Queued")
        }
    }
}
