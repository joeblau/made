import SwiftUI

/// A small glass sheet that asks for one line of text, replacing a system
/// `.alert` with an embedded `TextField` so every text input stays a Liquid
/// Glass field.
///
/// The sheet owns no business logic: the caller binds the text and decides
/// what Cancel and the confirm button do. The confirm button is the single
/// prominent action (BTN-1) and is disabled while the trimmed text is empty;
/// Return submits through it and Escape cancels. The sheet dismisses itself
/// after either callback runs.
///
///     .sheet(isPresented: $isPresented) {
///         TextPromptSheet(title: "Rename Group", label: "Group name",
///                         prompt: "Frontend", confirmTitle: "Save",
///                         text: $name) { rename(name) }
///     }
struct TextPromptSheet: View {
    let title: String
    /// The persistent visible label above the field (FORM-1). It is also the
    /// field's VoiceOver name.
    let label: String
    /// A bare example value for the placeholder (FORM-2). Without one the
    /// field would repeat the label as its placeholder.
    var prompt: String?
    let confirmTitle: String
    @Binding var text: String
    var onCancel: () -> Void = {}
    let onConfirm: () -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var isFieldFocused: Bool
    /// Return can reach both the field's submit and the default button;
    /// finish once so a confirm never runs twice.
    @State private var hasFinished = false

    private var canConfirm: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LiquidGlassMetrics.Spacing.large) {
            Text(title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            // Persistent label above the field; label → field stays at 8
            // (FORM-5).
            VStack(alignment: .leading, spacing: LiquidGlassMetrics.Spacing.xSmall) {
                Text(label)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    // The field carries this name for VoiceOver; hide the
                    // visible label so it is not read twice.
                    .accessibilityHidden(true)
                TextField(label, text: $text, prompt: prompt.map { Text($0) })
                    .accessibilityLabel(label)
                    .focused($isFieldFocused)
                    .onSubmit(confirm)
                    .liquidGlassField(isFocused: isFieldFocused)
            }

            CompatGlassContainer(spacing: 0) {
                HStack(spacing: LiquidGlassMetrics.Spacing.xSmall) {
                    Spacer()
                    Button("Cancel", role: .cancel, action: cancel)
                        .keyboardShortcut(.cancelAction)
                        .compatGlassButtonStyle()
                        .buttonBorderShape(.capsule)
                    Button(confirmTitle, action: confirm)
                        .keyboardShortcut(.defaultAction)
                        .compatGlassProminentButtonStyle()
                        .buttonBorderShape(.capsule)
                        .disabled(!canConfirm)
                }
            }
            .padding(.top, LiquidGlassMetrics.Spacing.xxSmall)
        }
        .padding(LiquidGlassMetrics.Spacing.xLarge)
        .frame(width: 360)
        .onAppear { isFieldFocused = true }
    }

    private func cancel() {
        guard !hasFinished else { return }
        hasFinished = true
        onCancel()
        dismiss()
    }

    private func confirm() {
        guard canConfirm, !hasFinished else { return }
        hasFinished = true
        onConfirm()
        dismiss()
    }
}
