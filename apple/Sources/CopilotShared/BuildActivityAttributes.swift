import ActivityKit
import Foundation

struct BuildActivityAttributes: ActivityAttributes {
    typealias ContentState = BuildActivityState

    let runKey: String
    let repository: String
    let branch: String
    let workflow: String
    let runID: Int
    let attempt: Int

    init(run: BuildWorkflowRun) {
        runKey = run.id
        repository = run.repository
        branch = run.branch
        workflow = run.workflow
        runID = run.runID
        attempt = run.attempt
    }

    var deepLink: URL { URL(string: "walkie://build/\(runID)")! }
    var runURL: URL { URL(string: "https://github.com/\(repository)/actions/runs/\(runID)/attempts/\(attempt)")! }
}
