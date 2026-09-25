import SwiftUI

/// What the toast above the record bar says.
struct ToastContent: Equatable, Identifiable {
    enum Role: Equatable { case success, failure }

    let id = UUID()
    let title: String
    let role: Role
    /// The saved session that Undo removes (nil hides Undo).
    let undoSessionID: UUID?

    var symbol: String { role == .success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill" }
    var tint: Color { role == .success ? .green : .red }
}

/// "Saved · 3.21 Wh" in a material capsule, with Undo. Shown by `RecordBar`
/// for five seconds after `SessionStore.saveCount` changes.
struct SavedToast: View {
    let content: ToastContent
    let onUndo: () -> Void
    let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bounce = 0

    var body: some View {
        HStack(spacing: 10) {
            Label {
                Text(content.title)
                    .font(.subheadline.weight(.medium).monospacedDigit())
                    .lineLimit(2)
            } icon: {
                Image(systemName: content.symbol)
                    .foregroundStyle(content.tint)
                    .symbolEffect(.bounce, options: .nonRepeating, value: bounce)
            }
            if content.undoSessionID != nil {
                Button("Undo", action: onUndo)
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 4)
                    .frame(minHeight: 44)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .frame(minHeight: 44)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
        .onAppear { if !reduceMotion { bounce += 1 } }
        .onTapGesture(perform: onDismiss)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(content.title)
        .accessibilityAddTraits(.isStaticText)
    }
}
