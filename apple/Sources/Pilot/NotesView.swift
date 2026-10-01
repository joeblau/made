import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let pilotNoteTab = UTType(exportedAs: "app.blau.pilot.note-tab")
}

/// The note whose tab is being dragged to reorder it. A dedicated Transferable
/// type — rather than the note's bare UUID string — keeps the drag from being
/// confused with generic text drags (which is why a plain-`String` payload
/// dropped unreliably), and mirrors the workspace pane tabs' drag payload.
struct NoteTabTransfer: Codable, Transferable {
    let id: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .pilotNoteTab)
    }
}

private enum NoteWordWrap: Int, CaseIterable, Identifiable {
    case eighty = 80
    case oneTwenty = 120
    case none = 0

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .eighty: "80 characters"
        case .oneTwenty: "120 characters"
        case .none: "None"
        }
    }

    var compactTitle: String {
        switch self {
        case .eighty: "80"
        case .oneTwenty: "120"
        case .none: "None"
        }
    }

    var columnCount: Int? {
        self == .none ? nil : rawValue
    }
}

/// Detail-area view for the global Notes mode (toggled with ⌘0). Renders a
/// horizontal tab bar of notes across the top with a text editor below for
/// the selected note — the same shape as the browser/terminal tab strip.
struct NotesView: View {
    @Bindable var store: WorkspaceStore
    @AppStorage("notes.wordWrap") private var wordWrapRawValue = NoteWordWrap.eighty.rawValue
    @State private var showCopiedToast = false
    @State private var toastDismiss: DispatchWorkItem?
    /// Tab the dragged note would be inserted before; drives the insertion marker.
    @State private var dropTargetNoteID: UUID?

    var body: some View {
        let notes = store.notes
        VStack(spacing: 0) {
            tabBar(notes: notes)
            secretStorageDisclosure
            editor
        }
        .overlay(alignment: .bottom) {
            if showCopiedToast {
                CopiedSecretToast()
                    .padding(.bottom, 24)
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
                    .allowsHitTesting(false)
            }
        }
        .confirmationDialog(
            "Delete this note?",
            isPresented: Binding(
                get: { store.notePendingClose != nil },
                set: { if !$0 { store.notePendingClose = nil } }
            ),
            presenting: store.notePendingClose
        ) { note in
            Button("Delete Note", role: .destructive) {
                store.deleteNote(note)
                store.notePendingClose = nil
            }
            Button("Cancel", role: .cancel) { store.notePendingClose = nil }
        } message: { note in
            Text("“\(note.displayTitle)” will be permanently deleted. This can’t be undone.")
        }
    }

    private var secretStorageDisclosure: some View {
        Label(
            "Secret masking is visual only. Notes are stored locally as plaintext—do not use Notes as a secret manager.",
            systemImage: "eye.slash"
        )
        .scaledFont(size: 11)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .accessibilityLabel(
            "Security notice: secret masking is visual only. Notes are stored locally as plaintext."
        )
    }

    private func flashCopiedToast() {
        toastDismiss?.cancel()
        withAnimation(.snappy(duration: 0.18)) { showCopiedToast = true }
        let work = DispatchWorkItem {
            withAnimation(.snappy(duration: 0.3)) { showCopiedToast = false }
        }
        toastDismiss = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    private func tabBar(notes: [Note]) -> some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                CompatGlassContainer(spacing: 8) {
                    HStack(spacing: 8) {
                        ForEach(notes) { note in
                            NoteTab(
                                title: note.displayTitle,
                                isSelected: note.id == store.selectedNoteID,
                                isDropTarget: dropTargetNoteID == note.id,
                                onSelect: { store.selectedNoteID = note.id },
                                onClose: { store.requestCloseNote(note) }
                            )
                            // Drag-to-reorder (issue #67). The note rides along as a
                            // dedicated Transferable payload; dropping onto another tab
                            // inserts the dragged note just before it and persists the
                            // new order.
                            .draggable(NoteTabTransfer(id: note.id)) {
                                // Legible chip under the cursor while dragging.
                                Text(note.displayTitle)
                                    .scaledFont(size: 12)
                                    .lineLimit(1)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(
                                        .ultraThinMaterial,
                                        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    )
                            }
                            .dropDestination(for: NoteTabTransfer.self) { items, _ in
                                dropTargetNoteID = nil
                                guard let dragged = items.first else { return false }
                                store.moveNote(dragged.id, before: note.id)
                                return true
                            } isTargeted: { targeted in
                                dropTargetNoteID = targeted ? note.id : nil
                            }
                        }

                        Button {
                            store.addNote()
                        } label: {
                            Image(systemName: "plus")
                                .scaledFont(size: 12, weight: .medium)
                        }
                        .compatGlassButtonStyle()
                        .buttonBorderShape(.circle)
                        .foregroundStyle(.primary)
                        .help("New Note")
                        // Dropping a tab on (or past) the + button sends it to the end.
                        .dropDestination(for: NoteTabTransfer.self) { items, _ in
                            guard let dragged = items.first else { return false }
                            store.moveNoteToEnd(dragged.id)
                            return true
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }

            wordWrapMenu
                .padding(.horizontal, 12)
        }
    }

    private var selectedWordWrap: NoteWordWrap {
        NoteWordWrap(rawValue: wordWrapRawValue) ?? .eighty
    }

    private var wordWrapMenu: some View {
        Menu {
            ForEach(NoteWordWrap.allCases) { option in
                Button {
                    wordWrapRawValue = option.rawValue
                } label: {
                    if option == selectedWordWrap {
                        Label(option.title, systemImage: "checkmark")
                    } else {
                        Text(option.title)
                    }
                }
            }
        } label: {
            Label("Word Wrap: \(selectedWordWrap.compactTitle)", systemImage: "text.word.spacing")
                .scaledFont(size: 11, weight: .medium)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Word Wrap")
    }

    @ViewBuilder
    private var editor: some View {
        if let note = store.selectedNote {
            NoteEditor(
                note: note,
                wordWrapColumns: selectedWordWrap.columnCount,
                onCopySecret: flashCopiedToast
            )
                // Re-create the editor when the selected note changes so the
                // text view rebinds cleanly instead of reusing stale state.
                .id(note.id)
        } else {
            ContentUnavailableView(
                "No Note",
                systemImage: "note.text",
                description: Text("Create a note with the + button.")
            )
        }
    }
}

private struct NoteEditor: View {
    @Bindable var note: Note
    let wordWrapColumns: Int?
    let onCopySecret: () -> Void
    @Environment(\.uiZoom) private var uiZoom

    var body: some View {
        NoteTextView(
            text: $note.body,
            fontSize: 13 * uiZoom,
            wordWrapColumns: wordWrapColumns,
            onCopySecret: onCopySecret
        )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: note.body) {
                _ = note.modelContext?.saveReporting(operation: "Saving note")
            }
    }
}

private struct CopiedSecretToast: View {
    var body: some View {
        Label("Copied", systemImage: "checkmark.circle.fill")
            .scaledFont(size: 13, weight: .semibold)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.3), radius: 10, y: 3)
    }
}

private struct NoteTab: View {
    let title: String
    let isSelected: Bool
    let isDropTarget: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .scaledFont(size: 12, weight: isSelected ? .semibold : .regular)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .scaledFont(size: 9, weight: .bold)
                    .frame(width: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            // Reserve the trailing slot so hovering never shifts the title.
            .opacity(isHovering || isSelected ? 1 : 0)
            .disabled(!isHovering && !isSelected)
            .allowsHitTesting(isHovering || isSelected)
            .accessibilityHidden(!isHovering && !isSelected)
            .help("Close Note")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(maxWidth: 170, alignment: .leading)
        .compatGlassEffect(
            tint: isSelected ? Color.accentColor.opacity(0.14) : nil,
            interactive: true,
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
        // Insertion marker on the leading edge — a drop places the dragged tab
        // just before this one.
        .overlay(alignment: .leading) {
            if isDropTarget {
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 3)
                    .padding(.vertical, 2)
                    .offset(x: -4)
            }
        }
        .animation(.easeInOut(duration: 0.12), value: isDropTarget)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
    }
}
