import Foundation

/// An RFC 5545 recurrence rule, in the subset a family calendar uses.
///
/// Rules are stored verbatim as text and expanded here, on the device, because
/// everything downstream needs concrete instants: a notification is scheduled
/// for a moment, not for a pattern.
///
/// Supported: `FREQ` (daily, weekly, monthly, yearly), `INTERVAL`, `COUNT`,
/// `UNTIL`, `BYDAY` for weekly rules, `BYMONTHDAY` for monthly ones. Anything
/// else in the string is ignored rather than rejected — a rule that arrives from
/// a future version of the app should still produce the occurrences it can.
///
/// The cases in `Tests/Fixtures/recurrence.json` are checked against
/// python-dateutil, so what this agrees with is the standard rather than this
/// project's reading of it.
public struct RecurrenceRule: Equatable, Sendable {
    public enum Frequency: String, Sendable {
        case daily = "DAILY"
        case weekly = "WEEKLY"
        case monthly = "MONTHLY"
        case yearly = "YEARLY"
    }

    public var frequency: Frequency
    public var interval: Int
    public var count: Int?
    public var until: Date?
    /// Gregorian weekday numbers (Sunday = 1), for weekly rules.
    public var byWeekday: [Int]
    public var byMonthDay: [Int]

    /// Stops a malformed or absurd rule from spinning. Far beyond anything a
    /// household would write, and reached only by a rule that generates nothing
    /// inside the window.
    static let maximumPeriods = 20_000

    public init?(_ text: String?) {
        guard let text, !text.isEmpty else { return nil }

        var parts: [String: String] = [:]
        for component in text.uppercased().split(separator: ";") {
            let pair = component.split(separator: "=", maxSplits: 1)
            guard pair.count == 2 else { continue }
            parts[String(pair[0])] = String(pair[1])
        }

        guard let frequency = parts["FREQ"].flatMap(Frequency.init(rawValue:)) else {
            return nil
        }
        self.frequency = frequency
        self.interval = max(1, parts["INTERVAL"].flatMap(Int.init) ?? 1)
        self.count = parts["COUNT"].flatMap(Int.init)
        self.until = parts["UNTIL"].flatMap(Self.parseUntil)
        self.byWeekday = parts["BYDAY"]?
            .split(separator: ",")
            .compactMap { Self.weekdays[String($0.suffix(2))] } ?? []
        self.byMonthDay = parts["BYMONTHDAY"]?
            .split(separator: ",")
            .compactMap { Int($0) } ?? []
    }

    static let weekdays: [String: Int] = [
        "SU": 1, "MO": 2, "TU": 3, "WE": 4, "TH": 5, "FR": 6, "SA": 7,
    ]

    /// `UNTIL` is basic-format ISO 8601, not the extended format the wire uses.
    static func parseUntil(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyyMMdd'T'HHmmss'Z'", "yyyyMMdd'T'HHmmss", "yyyyMMdd"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }
}

/// Expanding a task's rule into the instants inside a window.
public enum Recurrence {
    /// A UTC calendar with Monday as the first day, which is `WKST=MO`, the
    /// default the standard specifies.
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 2
        return calendar
    }

    /// Every instant the task falls on inside `window`, cancelled ones removed.
    ///
    /// The window is half-open: an occurrence exactly at the upper bound
    /// belongs to the next window, so a caller walking day by day never gets
    /// the same instant twice.
    public static func occurrences(
        of task: CalendarTask, in window: Range<Date>
    ) -> [Date] {
        guard let start = task.startsAt else { return [] }

        let exceptions = Set(task.recurrenceExceptionDates.map(Timestamp.truncatedToMilliseconds))

        guard let rule = RecurrenceRule(task.rrule) else {
            // No rule: the task happens once.
            return window.contains(start) && !exceptions.contains(Timestamp.truncatedToMilliseconds(start))
                ? [start]
                : []
        }

        return expand(rule: rule, from: start, in: window)
            .filter { !exceptions.contains(Timestamp.truncatedToMilliseconds($0)) }
    }

    static func expand(rule: RecurrenceRule, from start: Date, in window: Range<Date>) -> [Date] {
        let calendar = calendar
        var found: [Date] = []
        var produced = 0
        var period = 0

        while period < RecurrenceRule.maximumPeriods {
            defer { period += 1 }

            let candidates = candidates(for: rule, period: period, start: start, calendar: calendar)
            // An empty period is a month without a 31st, not the end of the
            // rule, so keep going.
            guard let last = candidates.last else {
                if isExhausted(rule: rule, period: period, start: start, window: window, calendar: calendar) {
                    break
                }
                continue
            }

            for candidate in candidates {
                guard candidate >= start else { continue }
                if let until = rule.until, candidate > until { return found }
                if let count = rule.count, produced >= count { return found }
                produced += 1

                if window.contains(candidate) {
                    found.append(candidate)
                } else if candidate >= window.upperBound {
                    // Past the window, and every later one is too — unless a
                    // count is still being honoured, which only matters for
                    // cutting the rule short, not for finding more.
                    return found
                }
            }

            if last >= window.upperBound { break }
        }

        return found
    }

    /// Whether a period that produced nothing means the rule is over.
    private static func isExhausted(
        rule: RecurrenceRule, period: Int, start: Date, window: Range<Date>, calendar: Calendar
    ) -> Bool {
        guard let anchor = periodStart(for: rule, period: period, start: start, calendar: calendar) else {
            return true
        }
        if let until = rule.until, anchor > until { return true }
        return anchor >= window.upperBound
    }

    private static func periodStart(
        for rule: RecurrenceRule, period: Int, start: Date, calendar: Calendar
    ) -> Date? {
        let step = period * rule.interval
        switch rule.frequency {
        case .daily: return calendar.date(byAdding: .day, value: step, to: start)
        case .weekly: return calendar.date(byAdding: .weekOfYear, value: step, to: start)
        case .monthly: return calendar.date(byAdding: .month, value: step, to: start)
        case .yearly: return calendar.date(byAdding: .year, value: step, to: start)
        }
    }

    /// The instants one period of the rule produces, in order.
    private static func candidates(
        for rule: RecurrenceRule, period: Int, start: Date, calendar: Calendar
    ) -> [Date] {
        let step = period * rule.interval
        let time = calendar.dateComponents([.hour, .minute, .second, .nanosecond], from: start)

        switch rule.frequency {
        case .daily:
            return [calendar.date(byAdding: .day, value: step, to: start)].compactMap { $0 }

        case .weekly:
            guard
                let weekOfStart = calendar.dateInterval(of: .weekOfYear, for: start)?.start,
                let weekStart = calendar.date(byAdding: .weekOfYear, value: step, to: weekOfStart)
            else {
                return []
            }
            let weekdays = rule.byWeekday.isEmpty
                ? [calendar.component(.weekday, from: start)]
                : rule.byWeekday.sorted { sortKey($0, calendar: calendar) < sortKey($1, calendar: calendar) }

            return weekdays.compactMap { weekday in
                let offset = sortKey(weekday, calendar: calendar)
                guard let day = calendar.date(byAdding: .day, value: offset, to: weekStart) else {
                    return nil
                }
                return at(time: time, on: day, calendar: calendar)
            }

        case .monthly:
            guard let month = calendar.date(byAdding: .month, value: step, to: startOfMonth(start, calendar)) else {
                return []
            }
            let days = rule.byMonthDay.isEmpty
                ? [calendar.component(.day, from: start)]
                : rule.byMonthDay.sorted()
            let available = calendar.range(of: .day, in: .month, for: month) ?? 1..<1

            return days.compactMap { day in
                // A month without a 31st simply has no occurrence: the rule
                // skips it rather than sliding to the 30th.
                guard available.contains(day) else { return nil }
                var components = calendar.dateComponents([.year, .month], from: month)
                components.day = day
                guard let date = calendar.date(from: components) else { return nil }
                return at(time: time, on: date, calendar: calendar)
            }

        case .yearly:
            var components = calendar.dateComponents([.year, .month, .day], from: start)
            components.year = (components.year ?? 0) + step
            // The same reasoning as the 31st: 29 February is not 1 March.
            guard let date = calendar.date(from: components),
                  calendar.component(.day, from: date) == (components.day ?? 0)
            else {
                return []
            }
            return [at(time: time, on: date, calendar: calendar)].compactMap { $0 }
        }
    }

    /// Days from the start of the week (Monday) to this weekday.
    private static func sortKey(_ weekday: Int, calendar: Calendar) -> Int {
        (weekday - calendar.firstWeekday + 7) % 7
    }

    private static func startOfMonth(_ date: Date, _ calendar: Calendar) -> Date {
        calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? date
    }

    private static func at(time: DateComponents, on day: Date, calendar: Calendar) -> Date? {
        var components = calendar.dateComponents([.year, .month, .day], from: day)
        components.hour = time.hour
        components.minute = time.minute
        components.second = time.second
        components.nanosecond = time.nanosecond
        return calendar.date(from: components)
    }
}
