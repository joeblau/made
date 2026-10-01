import Foundation
import SwiftData

/// Versioned schema + migration plan for Pilot's local SwiftData store.
///
/// Declaring an explicit version and plan makes app upgrades migrate the store
/// deterministically instead of failing to open (which previously caused the
/// corruption handler to quarantine — and once, destroy — real user data).
///
/// SwiftData handles *additive* changes (a new `@Model`, or a new stored
/// property that has a default value) automatically as a lightweight migration.
/// *Non-additive* changes (renaming a property, changing a type, changing a
/// uniqueness constraint or relationship) are NOT automatic and must be given an
/// explicit `MigrationStage` here, or the store will fail to open on upgrade.
///
/// To evolve the schema safely:
///   1. Copy the current models' shape into a new `PilotSchemaV2` enum
///      (snapshot — do not just point at the live types if they changed).
///   2. Append `PilotSchemaV2.self` to `schemas` (newest last).
///   3. Add a `MigrationStage` from V1 to V2 in `stages`:
///      `.lightweight` for additive changes, `.custom` otherwise.
///   4. Point `PilotPersistentStore.currentSchema` at the newest version.
/// Never edit a shipped version's `models` in place — that is exactly what
/// breaks upgrades and risks data loss.
/// V1 is a FROZEN SNAPSHOT of the shipped model shapes — nested copies, not
/// the live classes (rule 1 above). Pointing V1 at the live types crashes
/// every store upgrade with "Duplicate version checksums detected.":
/// `ExtensionWorkspaceLink.workspace` injects an implicit inverse into the
/// live `Workspace` entity, so a live-class V1 would hash identically to V2
/// and CoreData's staged migration aborts with an uncaught NSException.
/// Nested types keep the entity names ("Workspace", not the qualified name),
/// which is what makes the snapshot's checksum match the stamp already in
/// users' stores. Never edit these snapshot classes.
enum PilotSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [
            Workspace.self,
            Pane.self,
            BrowserState.self,
            EditorState.self,
            Note.self,
            RemoteDesktopConnection.self,
        ]
    }

    @Model
    final class Workspace {
        #Unique([\Workspace.id])

        var id: UUID = UUID()
        var name: String = ""
        var selectedPaneID: UUID?
        var frontmostTerminalPaneID: UUID?
        var axisRaw: String = "vertical"
        var isInspectorPresented: Bool = false
        var inspectorTabRaw: String = "Actions"
        var focusedPaneID: UUID?
        var isPinned: Bool = false
        var workspaceSortOrder: Int = 0
        var rootPath: String = ""
        var rootPathSourceRaw: String? = "automatic"
        var actionBadgeCount: Int = 0

        @Relationship(deleteRule: .cascade, inverse: \Pane.workspace)
        var panes: [Pane] = []

        init() {}
    }

    @Model
    final class Pane {
        #Unique([\Pane.id])

        var id: UUID = UUID()
        var kindRaw: String = "terminal"
        var sortOrder: Int = 0
        var currentDirectory: String = ""
        var bellCount: Int = 0
        var sizeFraction: Double = 0
        var isCollapsed: Bool = false
        var restoredSizeFraction: Double = 0
        var wasCollapsedBeforeFocus: Bool = false

        @Relationship(deleteRule: .cascade)
        var browserState: BrowserState?

        @Relationship(deleteRule: .cascade)
        var editorState: EditorState?

        var workspace: Workspace?

        init() {}
    }

    @Model
    final class BrowserState {
        var urlText: String = ""
        var appearanceModeRaw: String = "System"
        var navigationRequestID: Int = 0
        var inspectorToggleRequestID: Int = 0

        init() {}
    }

    @Model
    final class EditorState {
        var filePath: String = ""

        init() {}
    }

    @Model
    final class Note {
        #Unique([\Note.id])

        var id: UUID = UUID()
        var body: String = ""
        var sortOrder: Int = 0
        var createdAt: Date = Date()

        init() {}
    }

    @Model
    final class RemoteDesktopConnection {
        #Unique([\RemoteDesktopConnection.id])

        var id: UUID = UUID()
        var host: String = ""
        var port: Int = 5900
        var nickname: String = ""
        var username: String = ""
        var sortOrder: Int = 0
        var createdAt: Date = Date()
        var lastConnectedAt: Date?

        init() {}
    }
}

/// V2 is a frozen snapshot of the shipped Extension ownership/link schema.
/// It must remain unchanged now that V3 adds the browser-engine discriminator.
enum PilotSchemaV2: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [
            Workspace.self,
            Pane.self,
            BrowserState.self,
            EditorState.self,
            Note.self,
            RemoteDesktopConnection.self,
            ExtensionWorkspaceLink.self,
        ]
    }

    @Model
    final class Workspace {
        #Unique([\Workspace.id])

        var id: UUID = UUID()
        var name: String = ""
        var selectedPaneID: UUID?
        var frontmostTerminalPaneID: UUID?
        var axisRaw: String = "vertical"
        var isInspectorPresented: Bool = false
        var inspectorTabRaw: String = "Actions"
        var focusedPaneID: UUID?
        var isPinned: Bool = false
        var workspaceSortOrder: Int = 0
        var rootPath: String = ""
        var rootPathSourceRaw: String? = "automatic"
        var actionBadgeCount: Int = 0

        @Relationship(deleteRule: .cascade, inverse: \Pane.workspace)
        var panes: [Pane] = []

        init() {}
    }

    @Model
    final class Pane {
        #Unique([\Pane.id])

        var id: UUID = UUID()
        var kindRaw: String = "terminal"
        var sortOrder: Int = 0
        var currentDirectory: String = ""
        var bellCount: Int = 0
        var sizeFraction: Double = 0
        var isCollapsed: Bool = false
        var restoredSizeFraction: Double = 0
        var wasCollapsedBeforeFocus: Bool = false

        @Relationship(deleteRule: .cascade)
        var browserState: BrowserState?

        @Relationship(deleteRule: .cascade)
        var editorState: EditorState?

        var workspace: Workspace?

        init() {}
    }

    @Model
    final class BrowserState {
        var urlText: String = ""
        var appearanceModeRaw: String = "System"
        var navigationRequestID: Int = 0
        var inspectorToggleRequestID: Int = 0

        init() {}
    }

    @Model
    final class EditorState {
        var filePath: String = ""

        init() {}
    }

    @Model
    final class Note {
        #Unique([\Note.id])

        var id: UUID = UUID()
        var body: String = ""
        var sortOrder: Int = 0
        var createdAt: Date = Date()

        init() {}
    }

    @Model
    final class RemoteDesktopConnection {
        #Unique([\RemoteDesktopConnection.id])

        var id: UUID = UUID()
        var host: String = ""
        var port: Int = 5900
        var nickname: String = ""
        var username: String = ""
        var sortOrder: Int = 0
        var createdAt: Date = Date()
        var lastConnectedAt: Date?

        init() {}
    }

    @Model
    final class ExtensionWorkspaceLink {
        var sourceWorkspaceID: UUID = UUID()

        @Relationship(deleteRule: .cascade)
        var workspace: Workspace?

        init() {}
    }
}

/// Adds a persisted browser-engine discriminator. The live BrowserState
/// supplies WebKit as the property default, so V2 stores migrate without
/// changing the behavior of existing browser panes.
enum PilotSchemaV3: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(3, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [
            Workspace.self,
            Pane.self,
            BrowserState.self,
            EditorState.self,
            Note.self,
            RemoteDesktopConnection.self,
            ExtensionWorkspaceLink.self,
        ]
    }
}

enum PilotMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [PilotSchemaV1.self, PilotSchemaV2.self, PilotSchemaV3.self]
    }

    /// One stage per version-to-version upgrade; append a stage whenever a
    /// new `PilotSchemaV*` is added above.
    static var stages: [MigrationStage] {
        [
            .lightweight(fromVersion: PilotSchemaV1.self, toVersion: PilotSchemaV2.self),
            .lightweight(fromVersion: PilotSchemaV2.self, toVersion: PilotSchemaV3.self),
        ]
    }
}
