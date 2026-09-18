import Foundation

/// When the widget needs to look different, worked out without touching
/// WidgetKit.
///
/// WidgetKit asks for entries in advance and then leaves the widget alone, so a
/// missed moment is a widget that quietly shows the wrong thing for hours. The
/// moments that matter are: now, every time an event starts or ends — which is
/// when "next" changes — and the turn of the day.
public enum WidgetTimeline {
    /// WidgetKit is not generous with refreshes, and a timeline it considers
    /// unreasonable is one it will not honour. A day's worth of turning points
    /// fits comfortably.
    public static let maximumEntries = 24

    /// The instants the widget should be redrawn at, in order, starting at `now`.
    public static func points(
        taskStarts: [Date],
        taskEnds: [Date],
        now: Date,
        endOfDay: Date,
        limit: Int = maximumEntries
    ) -> [Date] {
        var moments: Set<Date> = [now]

        for moment in taskStarts + taskEnds where moment > now && moment < endOfDay {
            moments.insert(moment)
        }

        // The turn of the day, so an empty tomorrow replaces a finished today
        // without waiting for the app to be opened.
        if endOfDay > now {
            moments.insert(endOfDay)
        }

        let ordered = moments.sorted()
        guard ordered.count > limit else { return ordered }

        // Keep the nearest ones: a widget showing the right thing for the next
        // few hours and then asking again beats one that is right at midnight
        // and wrong at lunchtime.
        return Array(ordered.prefix(limit))
    }

    /// The end of the entries, which is when WidgetKit should come back.
    public static func reloadAfter(_ points: [Date], now: Date) -> Date {
        // Never ask for a reload in the past, and never sit silent for longer
        // than an hour even when nothing is planned.
        max(points.last ?? now, now.addingTimeInterval(3600))
    }
}
