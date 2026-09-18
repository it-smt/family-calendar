import FamilyCalendarKit
import SwiftUI

/// «Твою правку заменили.»
///
/// Last-write-wins означает, что из двух офлайновых правок одной задачи одна
/// проигрывает — и проигрывает вместе с полями, которых победитель не касался.
/// Так устроен протокол. Это — то, что не даёт такому случиться за спиной:
/// вытесненная версия показана рядом с той, что её заменила, а вернуть своё —
/// одно нажатие, обычная правка с более свежей отметкой, которая выигрывает так
/// же, как выиграла чужая.
struct SupersededEditRow: View {
    let notice: SupersededEdit
    let onRestore: () -> Void
    let onDismiss: () -> Void

    /// Янтарный, а не красный: ничего не сломано и ничего не потеряно —
    /// просто победила не твоя версия. Вычисляемое, а не хранимое: хранимое
    /// private-поле сделало бы private и сам инициализатор.
    private var accent: Color { Theme.swatchColor(1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(accent))
                Text("Твою правку заменили")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
                Text(notice.supersededAt, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            VStack(alignment: .leading, spacing: 5) {
                ForEach(notice.differences()) { difference in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(label(for: difference.field))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 66, alignment: .leading)
                        Text(display(difference.mine))
                            .font(.caption)
                            .strikethrough()
                            .foregroundStyle(.secondary)
                        Image(systemName: "arrow.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.tertiary)
                        Text(display(difference.theirs))
                            .font(.caption.weight(.semibold))
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(accent.opacity(0.12))
            )

            HStack(spacing: 8) {
                Button(action: onRestore) {
                    Text("Вернуть моё")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(accent)
                        )
                }
                .buttonStyle(.plain)

                Button(action: onDismiss) {
                    Text("Оставить")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color(.tertiarySystemFill))
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .card(tint: accent)
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
