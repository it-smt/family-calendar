import FamilyCalendarKit
import SwiftUI

/// "Твою правку заменили."
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
            Label("Твою правку заменили", systemImage: "exclamationmark.arrow.circlepath")
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
                Button("Вернуть моё", action: onRestore)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button("Оставить", action: onDismiss)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }

    private func label(for field: String) -> String {
        switch field {
        case "title": "Название"
        case "starts_at": "Время"
        case "notes": "Заметки"
        case "location_name": "Место"
        case "deleted_at": "Удалено"
        case "completed_at": "Выполнено"
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
        case .bool(let flag): flag ? "да" : "нет"
        case .array, .object: "—"
        }
    }
}
