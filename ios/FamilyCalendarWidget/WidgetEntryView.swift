import AppIntents
import FamilyCalendarKit
import SwiftUI
import WidgetKit

struct WidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let snapshot: WidgetSnapshot

    var body: some View {
        switch family {
        case .systemSmall: SmallWidget(snapshot: snapshot)
        case .systemLarge: LargeWidget(snapshot: snapshot)
        default: MediumWidget(snapshot: snapshot)
        }
    }
}

/// Small: the next thing, and when to leave for it.
struct SmallWidget: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let next = snapshot.next {
                Text(next.title)
                    .font(.headline)
                    .lineLimit(2)

                if let leaveBy = next.leaveBy {
                    // Stage 8 fills this in with a real travel time.
                    Text("Leave \(leaveBy, style: .relative)")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if let startsAt = next.startsAt {
                    Text(startsAt, style: .time)
                        .font(.subheadline.monospacedDigit())
                    Text(startsAt, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("All day").font(.caption).foregroundStyle(.secondary)
                }

                if let place = next.locationName, !place.isEmpty {
                    Text(place).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            } else {
                Text("Nothing left today")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
            UnsyncedMark(count: snapshot.unsyncedCount)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Medium: the rest of today.
struct MediumWidget: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Today").font(.headline)
                Spacer()
                UnsyncedMark(count: snapshot.unsyncedCount)
                Text("\(snapshot.remaining) left")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if snapshot.today.isEmpty {
                Text("Nothing planned").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(snapshot.today.prefix(3)) { line in
                    TaskLineView(line: line)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// Large: today, and the shopping list.
struct LargeWidget: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Today").font(.headline)
                Spacer()
                UnsyncedMark(count: snapshot.unsyncedCount)
            }

            if snapshot.today.isEmpty {
                Text("Nothing planned").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(snapshot.today.prefix(5)) { line in
                    TaskLineView(line: line)
                }
            }

            if !snapshot.shopping.isEmpty {
                Divider()
                Text("To buy").font(.subheadline.weight(.medium))
                ForEach(snapshot.shopping.prefix(4)) { item in
                    HStack(spacing: 6) {
                        Image(systemName: "circle").font(.caption2).foregroundStyle(.secondary)
                        Text(item.title).font(.caption)
                        if let quantity = item.quantity, !quantity.isEmpty {
                            Text(quantity).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// One line, with the tick that makes the widget worth having.
struct TaskLineView: View {
    let line: WidgetSnapshot.TaskLine

    var body: some View {
        HStack(spacing: 8) {
            // The reason the widget is worth having: ticking something off
            // without opening anything.
            Button(
                intent: CompleteTaskIntent(
                    taskID: line.id, occurrence: line.occurrence, completed: !line.isCompleted
                )
            ) {
                Image(systemName: line.isCompleted ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(line.isCompleted ? .green : .secondary)
            }
            .buttonStyle(.plain)

            if let colorHex = line.colorHex {
                Capsule().fill(Color(widgetHex: colorHex)).frame(width: 3, height: 14)
            }

            Text(line.title)
                .font(.subheadline)
                .strikethrough(line.isCompleted)
                .foregroundStyle(line.isCompleted ? .secondary : .primary)
                .lineLimit(1)

            Spacer(minLength: 4)

            if let startsAt = line.startsAt {
                Text(startsAt, style: .time)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// The same small mark the app shows, for the same reason.
struct UnsyncedMark: View {
    let count: Int

    var body: some View {
        if count > 0 {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .accessibilityLabel("\(count) changes not synchronised")
        }
    }
}

extension Color {
    init(widgetHex hex: String) {
        let cleaned = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        self.init(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
