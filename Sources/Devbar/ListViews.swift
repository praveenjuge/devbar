import SwiftUI

/// A list section header that collapses its section. Collapsing is drawn
/// here rather than left to the list, which only shows its disclosure
/// arrow on hover.
struct CollapsibleHeader: View {
    let title: String
    let count: Int
    /// What the rows are, for VoiceOver: "3 worktrees".
    let noun: String
    @Binding var isExpanded: Bool
    var action: (title: String, help: String, run: () -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 10)
                    Text(title)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(count, format: .number)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title), \(count) \(noun)")
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .help(isExpanded ? "Collapse" : "Expand")
            Spacer()
            if let action {
                Button(action.title, action: action.run)
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .help(action.help)
            }
        }
    }
}

struct StatusPill: View {
    let title: String
    let color: Color
    /// Selected rows get an accent background, where colored text is hard to read.
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        let tint = prominence == .increased ? Color.white : color
        Text(title)
            .font(.caption)
            .fontWeight(.medium)
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(tint.opacity(0.15), in: Capsule())
    }
}
