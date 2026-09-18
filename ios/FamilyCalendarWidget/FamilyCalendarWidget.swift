import AppIntents
import FamilyCalendarKit
import SwiftUI
import WidgetKit

/// The widget.
///
/// Reads the shared database directly, in its own process. It never launches
/// the app, never waits for a network, and shows the same data the app does
/// because it is literally the same file.
@main
struct FamilyCalendarWidgetBundle: WidgetBundle {
    var body: some Widget {
        FamilyCalendarWidget()
        LeaveTimeLiveActivity()
    }
}

struct FamilyCalendarWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "FamilyCalendarWidget", provider: Provider()) { entry in
            WidgetEntryView(snapshot: entry.snapshot)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Today")
        .description("What is next, and what to buy.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct Entry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry {
        Entry(date: .now, snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        completion(load().first ?? placeholder(in: context))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        let entries = load()
        let points = entries.map(\.date)
        completion(
            Timeline(
                entries: entries,
                policy: .after(WidgetTimeline.reloadAfter(points, now: .now))
            )
        )
    }

    /// Reading the database is the whole of loading. If it fails the widget
    /// shows an empty day rather than an error: a widget is not a place to
    /// report problems.
    private func load() -> [Entry] {
        do {
            let snapshots = try WidgetStore.shared().timeline()
            return snapshots.map { Entry(date: $0.date, snapshot: $0) }
        } catch {
            Log.database.error("widget could not read: \(error.localizedDescription, privacy: .public)")
            return [Entry(date: .now, snapshot: WidgetSnapshot(date: .now, today: [], shopping: [], unsyncedCount: 0))]
        }
    }
}
