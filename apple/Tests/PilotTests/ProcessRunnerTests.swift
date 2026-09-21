import Foundation
import Testing
@testable import Pilot

@Suite("Bounded process runner", .serialized)
struct ProcessRunnerTests {
    @Test("Deadline covers inherited output pipes after the child exits", arguments: [false, true])
    func inheritedPipesRespectDeadline(blocking: Bool) async throws {
        // The direct child exits successfully, but its descendant holds both
        // pipes open. A finite sleep also lets a regressed implementation fail
        // this test instead of hanging the test runner forever.
        let invocation = ProcessInvocation(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "sleep 3 & printf ready; printf error >&2; exit 0"],
            timeout: .milliseconds(150)
        )
        let started = ContinuousClock.now
        do {
            if blocking {
                _ = try await Task.detached { try ProcessRunner.runBlocking(invocation) }.value
            } else {
                _ = try await ProcessRunner.run(invocation)
            }
            Issue.record("Expected timeout while the descendant holds the pipes open")
        } catch let error as ProcessRunnerError {
            guard case .timedOut(let result) = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
            #expect(result.termination == .exit(0))
            #expect(result.standardOutputString == "ready")
            #expect(result.standardErrorString == "error")
        }
        #expect(started.duration(to: .now) < .seconds(1))
    }

    @Test("Cancellation interrupts inherited output pipes", arguments: [false, true])
    func inheritedPipesRespectCancellation(blocking: Bool) async throws {
        let invocation = ProcessInvocation(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "sleep 3 & exit 0"],
            timeout: .seconds(20)
        )
        let task = Task.detached {
            if blocking { return try ProcessRunner.runBlocking(invocation) }
            return try await ProcessRunner.run(invocation)
        }
        try await Task.sleep(for: .milliseconds(150))
        let started = ContinuousClock.now
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Expected cancellation while the descendant holds the pipes open")
        } catch let error as ProcessRunnerError {
            guard case .cancelled = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
        }
        #expect(started.duration(to: .now) < .seconds(1))
    }

    @Test("Nonzero exits return structured status without leaking output")
    func nonzeroExit() async throws {
        let invocation = ProcessInvocation(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf secret-output >&2; exit 23"],
            timeout: .seconds(2),
            redactedArgumentIndexes: [1]
        )
        do {
            _ = try await ProcessRunner.run(invocation)
            Issue.record("Expected the child to fail")
        } catch let error as ProcessRunnerError {
            guard case .nonZeroExit(let result) = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
            #expect(result.termination == .exit(23))
            #expect(result.standardErrorString == "secret-output")
            #expect(error.localizedDescription.contains("<redacted>"))
            #expect(!error.localizedDescription.contains("secret-output"))
            #expect(!error.localizedDescription.contains("printf"))
        }
    }

    @Test("Successful exit preserves buffered output from both streams")
    func bufferedOutputAfterExit() async throws {
        let result = try await ProcessRunner.run(ProcessInvocation(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "i=0; while [ $i -lt 10000 ]; do printf 0123456789; printf abcdefghij >&2; i=$((i+1)); done"],
            timeout: .seconds(5)
        ))
        #expect(result.termination == .exit(0))
        #expect(result.standardOutputString == String(repeating: "0123456789", count: 10000))
        #expect(result.standardErrorString == String(repeating: "abcdefghij", count: 10000))
    }

    @Test("Continuous output cannot starve the deadline")
    func continuousOutputRespectsDeadline() async throws {
        let started = ContinuousClock.now
        do {
            _ = try await ProcessRunner.run(ProcessInvocation(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "while :; do printf 0123456789abcdef; printf fedcba9876543210 >&2; done"],
                timeout: .milliseconds(150),
                standardOutputLimit: 256,
                standardErrorLimit: 256
            ))
            Issue.record("Expected timeout")
        } catch let error as ProcessRunnerError {
            guard case .timedOut(let result) = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
            #expect(result.standardOutput.count == 256)
            #expect(result.standardError.count == 256)
            #expect(result.standardOutputTruncated)
            #expect(result.standardErrorTruncated)
        }
        #expect(started.duration(to: .now) < .seconds(2))
    }

    @Test("Closed output streams do not hide a still-running child")
    func closedPipesStillRespectDeadline() async throws {
        do {
            _ = try await ProcessRunner.run(ProcessInvocation(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "exec >/dev/null 2>&1; exec sleep 3"],
                timeout: .milliseconds(100)
            ))
            Issue.record("Expected timeout")
        } catch let error as ProcessRunnerError {
            guard case .timedOut(let result) = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
            #expect(result.elapsed < .seconds(1))
        }
    }

    @Test("Launch failure returns without waiting for output")
    func launchFailure() async throws {
        let started = ContinuousClock.now
        do {
            _ = try await ProcessRunner.run(ProcessInvocation(
                executableURL: URL(fileURLWithPath: "/nonexistent-cockpit-test-\(UUID().uuidString)")
            ))
            Issue.record("Expected launch failure")
        } catch let error as ProcessRunnerError {
            guard case .launch = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
        }
        #expect(started.duration(to: .now) < .seconds(1))
    }

    @Test("Deadline terminates a hung child")
    func hungChild() async throws {
        let started = ContinuousClock.now
        do {
            _ = try await ProcessRunner.run(ProcessInvocation(
                executableURL: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["10"],
                timeout: .milliseconds(100)
            ))
            Issue.record("Expected timeout")
        } catch let error as ProcessRunnerError {
            guard case .timedOut = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
            #expect(started.duration(to: .now) < .seconds(2))
        }
    }

    @Test("Signal-ignoring child is killed after the grace period")
    func signalIgnoringChild() async throws {
        let started = ContinuousClock.now
        do {
            _ = try await ProcessRunner.run(ProcessInvocation(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "trap '' TERM; while :; do sleep 1; done"],
                timeout: .milliseconds(100),
                terminationGracePeriod: .milliseconds(100)
            ))
            Issue.record("Expected timeout")
        } catch let error as ProcessRunnerError {
            guard case .timedOut(let result) = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
            #expect(result.termination == .signal(SIGKILL))
            #expect(started.duration(to: .now) < .seconds(2))
        }
    }

    @Test("Cancellation terminates the child")
    func cancellation() async throws {
        let task = Task {
            try await ProcessRunner.run(ProcessInvocation(
                executableURL: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["10"],
                timeout: .seconds(20)
            ))
        }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch let error as ProcessRunnerError {
            guard case .cancelled = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
        }
    }

    @Test("Blocking bridge observes cancellation from its calling task")
    func blockingBridgeCancellation() async throws {
        let started = ContinuousClock.now
        let task = Task.detached {
            try ProcessRunner.runBlocking(ProcessInvocation(
                executableURL: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["10"],
                timeout: .seconds(20)
            ))
        }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch let error as ProcessRunnerError {
            guard case .cancelled = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
            #expect(started.duration(to: .now) < .seconds(2))
        }
    }

    @Test("Both output streams drain concurrently and enforce caps")
    func largeOutput() async throws {
        let script = "i=0; while [ $i -lt 8000 ]; do printf 0123456789abcdef; printf fedcba9876543210 >&2; i=$((i+1)); done"
        do {
            _ = try await ProcessRunner.run(ProcessInvocation(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", script],
                timeout: .seconds(5),
                standardOutputLimit: 4_096,
                standardErrorLimit: 2_048
            ))
            Issue.record("Expected a truncation error")
        } catch let error as ProcessRunnerError {
            guard case .outputTruncated(let result) = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
            #expect(result.standardOutput.count == 4_096)
            #expect(result.standardError.count == 2_048)
            #expect(result.standardOutputTruncated)
            #expect(result.standardErrorTruncated)
        }
    }
}
