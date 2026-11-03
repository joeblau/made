import Foundation

struct DroneAgentPlan: Sendable {
    let path: String
    let expectedSHA256: String?
    let oldData: Data
    let newData: Data
    let build: DroneToolProcessRequest
    let test: DroneToolProcessRequest
    let diff: DroneToolDiffRequest
    let idempotencyKeyPrefix: String

    init(
        path: String,
        expectedSHA256: String? = nil,
        oldData: Data,
        newData: Data,
        build: DroneToolProcessRequest,
        test: DroneToolProcessRequest,
        diff: DroneToolDiffRequest = DroneToolDiffRequest(),
        idempotencyKeyPrefix: String = DroneToolClient.makeIdempotencyKey()
    ) {
        self.path = path
        self.expectedSHA256 = expectedSHA256
        self.oldData = oldData
        self.newData = newData
        self.build = build
        self.test = test
        self.diff = diff
        self.idempotencyKeyPrefix = idempotencyKeyPrefix
    }
}

struct DroneAgentCommandReport: Equatable, Sendable {
    let completion: DroneToolCompletionBody
    let standardOutput: Data
    let standardError: Data
    let outputTruncated: Bool
}

struct DroneAgentReport: Equatable, Sendable {
    let edit: DroneToolEditResult
    let build: DroneAgentCommandReport
    let test: DroneAgentCommandReport
    let diff: Data
    let diffTruncated: Bool

    var diagnosticSummary: String {
        let buildStatus = build.completion.status.rawValue
        let testStatus = test.completion.status.rawValue
        let truncated = build.outputTruncated || test.outputTruncated || diffTruncated
        return "editBytes=\(edit.bytesWritten) build=\(buildStatus) test=\(testStatus) "
            + "buildOutputBytes=\(build.standardOutput.count + build.standardError.count) "
            + "testOutputBytes=\(test.standardOutput.count + test.standardError.count) "
            + "diffBytes=\(diff.count) truncated=\(truncated)"
    }
}

enum DroneAgentDriverError: Error, Equatable, Sendable {
    case invalidIdempotencyPrefix
    case readTruncated
    case editPreconditionFailed
    case commandFailed(stage: String, completion: DroneToolCompletionBody)
}

struct DroneAgentDriver: Sendable {
    let client: DroneToolClient

    func perform(_ plan: DroneAgentPlan) async throws -> DroneAgentReport {
        guard DroneEnvelope.isValidIdempotencyKey(plan.idempotencyKeyPrefix),
              plan.idempotencyKeyPrefix.utf8.count <= 112
        else { throw DroneAgentDriverError.invalidIdempotencyPrefix }

        let read = try await client.read(
            path: plan.path,
            maxBytes: DroneLimits.maxToolReadBytes,
            idempotencyKey: plan.idempotencyKeyPrefix + "-read"
        )
        guard !read.truncated else { throw DroneAgentDriverError.readTruncated }
        guard read.data.occurrences(of: plan.oldData) == 1 else {
            throw DroneAgentDriverError.editPreconditionFailed
        }

        let edit = try await client.edit(
            DroneToolEditRequest(
                path: plan.path,
                expectedSHA256: plan.expectedSHA256,
                oldData: plan.oldData,
                newData: plan.newData
            ),
            idempotencyKey: plan.idempotencyKeyPrefix + "-edit"
        )

        let buildCollector = DroneToolEventCollector()
        let buildCompletion = try await client.run(
            plan.build,
            idempotencyKey: plan.idempotencyKeyPrefix + "-build",
            onEvent: { event in await buildCollector.apply(event) }
        )
        guard buildCompletion.status == .succeeded, buildCompletion.exitCode == 0 else {
            throw DroneAgentDriverError.commandFailed(stage: "build", completion: buildCompletion)
        }

        let testCollector = DroneToolEventCollector()
        let testCompletion = try await client.run(
            plan.test,
            idempotencyKey: plan.idempotencyKeyPrefix + "-test",
            onEvent: { event in await testCollector.apply(event) }
        )
        guard testCompletion.status == .succeeded, testCompletion.exitCode == 0 else {
            throw DroneAgentDriverError.commandFailed(stage: "test", completion: testCompletion)
        }

        let diffCollector = DroneToolEventCollector()
        let diffCompletion = try await client.diff(
            plan.diff,
            idempotencyKey: plan.idempotencyKeyPrefix + "-diff",
            onEvent: { event in await diffCollector.apply(event) }
        )
        guard diffCompletion.status == .succeeded else {
            throw DroneAgentDriverError.commandFailed(stage: "diff", completion: diffCompletion)
        }

        return DroneAgentReport(
            edit: edit,
            build: await buildCollector.report(completion: buildCompletion),
            test: await testCollector.report(completion: testCompletion),
            diff: await diffCollector.data(for: .diff),
            diffTruncated: await diffCollector.isTruncated
        )
    }
}

private actor DroneToolEventCollector {
    private var standardOutput = Data()
    private var standardError = Data()
    private var diff = Data()
    private(set) var isTruncated = false

    func apply(_ event: DroneToolEvent) {
        guard case .output(let output) = event else { return }
        switch output.stream {
        case .standardOutput: standardOutput.append(output.data)
        case .standardError: standardError.append(output.data)
        case .diff: diff.append(output.data)
        }
        isTruncated = isTruncated || output.truncated
    }

    func data(for stream: DroneToolStream) -> Data {
        switch stream {
        case .standardOutput: standardOutput
        case .standardError: standardError
        case .diff: diff
        }
    }

    func report(completion: DroneToolCompletionBody) -> DroneAgentCommandReport {
        DroneAgentCommandReport(
            completion: completion,
            standardOutput: standardOutput,
            standardError: standardError,
            outputTruncated: isTruncated
        )
    }
}

private extension Data {
    func occurrences(of needle: Data) -> Int {
        guard !needle.isEmpty, needle.count <= count else { return 0 }
        var result = 0
        var start = startIndex
        while let range = range(of: needle, in: start ..< endIndex) {
            result += 1
            start = range.upperBound
        }
        return result
    }
}
