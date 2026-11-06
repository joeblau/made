import Foundation

@main
struct DroneJobToolProof {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let workspaceID = UUID()
        let jobs = try DroneJobEngine(
            stateURL: root.appendingPathComponent("state"),
            workspaces: DroneWorkspaceRegistry(workspaces: [workspaceID: workspace])
        )
        let engine = DroneJobToolEngine(jobs: jobs, maximumRetainedEntries: 2)
        func context(controller: UUID = UUID(), leaseID: UUID = UUID()) -> DroneToolRequestContext {
            DroneToolRequestContext(
                lease: DroneToolLease(
                    id: leaseID, controllerID: controller, droneID: UUID(), jobID: DroneJobID(),
                    workspaceID: workspaceID, expiresAt: Date().timeIntervalSince1970 + 600
                ), requestID: UUID(), idempotencyKey: "same-idempotency-key"
            )
        }
        let file = workspace.appendingPathComponent("file")
        try Data("old".utf8).write(to: file)
        let request = DroneToolEditRequest(path: "file", expectedSHA256: nil,
                                           oldData: Data("old".utf8), newData: Data("new".utf8))
        let first = context()
        async let one = engine.edit(request, context: first)
        async let two = engine.edit(request, context: first)
        let results = try await (one, two)
        precondition(results.0 == results.1)
        let retry = try await engine.edit(request, context: first)
        precondition(retry == results.0)
        do {
            _ = try await engine.edit(DroneToolEditRequest(path: "file", expectedSHA256: nil,
                oldData: Data("new".utf8), newData: Data("bad".utf8)), context: first)
            fatalError("conflicting retry accepted")
        } catch DroneProtocolError.idempotencyConflict {}
        do {
            _ = try await engine.edit(DroneToolEditRequest(path: "../file", expectedSHA256: nil,
                oldData: Data("old".utf8), newData: Data()), context: first)
            fatalError("cached invalid payload accepted")
        } catch DroneProtocolError.unauthorized {}
        try Data("old".utf8).write(to: file)
        _ = try await engine.edit(request, context: context())
        let contents = try Data(contentsOf: file)
        precondition(contents == Data("new".utf8))
        do {
            _ = try await engine.edit(request, context: context(controller: first.lease.controllerID))
            fatalError("full edit cache accepted new lease")
        } catch DroneProtocolError.resourceLimit {}
        print("Drone job tool proof passed: edit validation, scope, conflict, concurrent retry, retention")
    }
}
