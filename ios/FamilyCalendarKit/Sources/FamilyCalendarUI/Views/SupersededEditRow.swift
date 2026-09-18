import FamilyCalendarKit
import SwiftUI

/// "Your change was replaced."
///
/// Last-write-wins means one of two offline edits to the same task loses, and
/// it loses fields the winner never touched. That is the protocol. This is what
/// keeps it from happening behind someone's back: the replaced version is shown
/// with what replaced it, and putting it back is one tap — an ordinary edit
/// with a newer stamp, which wins the way anything else does.
struct SupersededEditRow: View {
    let notice: SupersededEdit
    let onRestore: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Your change was replaced", systemImage: "exclamationmark.arrow.circlepath")
                .font(.subheadline.weight(.medium))

            ForEach(notice.differences()) { difference in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(label(for: difference.field))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(display(difference.mine))
                        .font(.caption)
                        .strikethrough()
                    Image(systemName: "arrow.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(display(difference.theirs))
                        .font(.caption.weight(.medium))
                }
            }

            HStack {
                Button("Put mine back", action: onRestore)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button("Leave it", action: onDismiss)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }

    private func label(for field: String) -> String {
        switch field {
        case "title": "Title"
        case "starts_at": "Time"
        case "notes": "Notes"
        case "location_name": "Place"
        case "deleted_at": "Deleted"
        case "completed_at": "Done"
        default: field.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private func display(_ value: JSONValue) -> String {
        switch value {
        case .null: "—"
        case .string(let text):
            // Timestamps read better as times than as the strings they are
            // stored as.
            Timestamp.date(from: text)
                .map { $0.formatted(date: .abbreviated, time: .shortened) } ?? text
        case .int(let number): String(number)
        case .double(let number): String(number)
        case .bool(let flag): flag ? "yes" : "no"
        case .array, .object: "—"
        }
    }
}
