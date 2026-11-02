import SwiftUI

/// Asks for a short piece of text. Used instead of a system alert, because an alert puts keyboard focus on its
/// button and draws the system focus ring, where we want the cursor in the field and nothing else highlighted.
struct NameSheet: View {
    let title: String
    let message: String
    let placeholder: String
    let onSave: (String) -> Void
    let onCancel: () -> Void

    @State private var text: String
    @FocusState private var focused: Bool

    init(
        title: String,
        message: String,
        placeholder: String = "Name",
        initial: String,
        onSave: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.title = title
        self.message = message
        self.placeholder = placeholder
        self.onSave = onSave
        self.onCancel = onCancel
        _text = State(initialValue: initial)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(Theme.heading)
                Text(message)
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
            }

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(Theme.body)
                .focused($focused)
                .focusEffectDisabled()
                .onSubmit(save)
                .padding(.horizontal, 12)
                .frame(height: 36)
                .background(Theme.raised.opacity(0.7), in: RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                        .strokeBorder(focused ? Color.primary.opacity(0.35) : Theme.stroke)
                )

            HStack(spacing: 10) {
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(SecondaryButtonStyle(height: 34))
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .buttonStyle(PrimaryButtonStyle(height: 34))
            }
        }
        .padding(20)
        .frame(width: 340)
        .background(Theme.canvas)
        .focusEffectDisabled()
        .defaultFocus($focused, true)
        .onAppear { focused = true }
    }

    private func save() {
        onSave(text)
    }
}
