import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let pilotWorkspace = UTType(exportedAs: "app.blau.pilot.workspace")
}

struct WorkspaceSidebarDragPayload: Codable, Sendable, Transferable {
    let item: WorkspaceSidebarItem

    init(workspaceID: UUID) { item = .workspace(workspaceID) }
    init(groupID: UUID) { item = .group(groupID) }

    var workspaceID: UUID? {
        guard case .workspace(let id) = item else { return nil }
        return id
    }

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .pilotWorkspace)
    }

    @discardableResult
    static func load(
        _ providers: [NSItemProvider],
        perform action: @escaping @MainActor @Sendable (Self) -> Void
    ) -> Bool {
        guard providers.count == 1, let provider = providers.first,
              provider.hasItemConformingToTypeIdentifier(UTType.pilotWorkspace.identifier) else { return false }
        provider.loadDataRepresentation(forTypeIdentifier: UTType.pilotWorkspace.identifier) { data, _ in
            guard let data, let payload = try? JSONDecoder().decode(Self.self, from: data) else { return }
            Task { @MainActor in action(payload) }
        }
        return true
    }
}
