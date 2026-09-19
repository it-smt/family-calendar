import FamilyCalendarKit
import Foundation
import OSLog
import Observation

/// One appearance of a task on a day.
///
/// A repeating task is one row and many instants, so the list is of these
/// rather than of tasks: the same "вынести мусор" is a different line on
/// Monday and on Tuesday, and the time shown is the instant, not the row's.
public struct DayItem: Identifiable, Sendable {
    public let task: CalendarTask
    public let occurrence: Date
    /// Whether *this* instant is done.
    ///
    /// For a task that happens once it is the task's own flag. For a repeat it
    /// is a row of its own, because one row and a rule have nowhere to put
    /// "this Tuesday went differently".
    public let isCompleted: Bool

    public var id: String {
        "\(task.id.uuidString)@\(Timestamp.string(from: occurrence))"
    }

    public var isRepeating: Bool { task.rrule != nil }
}

/// Насколько широко смотрим.
public enum CalendarScale: String, CaseIterable, Sendable, Identifiable {
    case day, week, month

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .day: "День"
        case .week: "Неделя"
        case .month: "Месяц"
        }
    }
}

/// The day list.
///
/// Reads the database and nothing else. A change from the partner arrives by
/// the same path as a change made here — the sync engine writes to the database
/// and the observation fires — so there is no "refresh" anywhere in this file.
@MainActor
@Observable
public final class DayViewModel {
    public private(set) var tasks: [CalendarTask] = []
    public private(set) var categories: [UUID: TaskCategory] = [:]
    public private(set) var people: [UUID: User] = [:]
    public private(set) var notices: [SupersededEdit] = []
    /// How much of each task's list is ticked off, for every task at once.
    public private(set) var packing: [UUID: SubtaskProgress] = [:]
    /// Which tasks will ring. The bell on a card is the only way to tell
    /// without opening it.
    public private(set) var alerts: Set<UUID> = []
    /// Ticked-off instants of repeats, for the window being shown.
    public private(set) var completions: Set<CompletedOccurrence> = []

    public var day: Date {
        didSet {
            // Неделя и месяц перечитываются только когда сменился их отрезок,
            // а не на каждый выбранный день внутри него.
            guard !Calendar.current.isDate(day, equalTo: oldValue, toGranularity: granularity)
            else { return }
            restartTaskObservation()
        }
    }

    public var scale: CalendarScale = .day {
        didSet {
            guard scale != oldValue else { return }
            restartTaskObservation()
        }
    }

    private var granularity: Calendar.Component {
        switch scale {
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        }
    }

    /// Отрезок, который сейчас читается из базы.
    public var range: Range<Date> {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: day)

        switch scale {
        case .day:
            return start..<(calendar.date(byAdding: .day, value: 1, to: start) ?? start)
        case .week:
            guard let week = calendar.dateInterval(of: .weekOfYear, for: day) else {
                return start..<start
            }
            return week.start..<week.end
        case .month:
            // Сетка месяца показывает и хвосты соседних месяцев, поэтому
            // читается вся она, а не календарный месяц.
            guard
                let month = calendar.dateInterval(of: .month, for: day),
                let first = calendar.dateInterval(of: .weekOfYear, for: month.start),
                let last = calendar.dateInterval(
                    of: .weekOfYear, for: month.end.addingTimeInterval(-1)
                )
            else { return start..<start }
            return first.start..<last.end
        }
    }

    /// Filters. Both are plain local state — filtering never goes near a query
    /// the network could be involved in.
    public var categoryFilter: UUID? { didSet { restartTaskObservation() } }
    public var assigneeFilter: UUID? { didSet { restartTaskObservation() } }

    private let environment: AppEnvironment
    private var taskObservation: Task<Void, Never>?
    private var completionObservation: Task<Void, Never>?
    private var supportObservation: Task<Void, Never>?

    public init(environment: AppEnvironment, day: Date = Date()) {
        self.environment = environment
        self.day = day
    }

    /// Всё, что попадает в отрезок, с развёрнутыми повторами.
    public var items: [DayItem] {
        let window = range
        var items: [DayItem] = []
        for task in tasks {
            if let categoryFilter, task.categoryID != categoryFilter { continue }
            if let assigneeFilter, task.assigneeID != assigneeFilter { continue }
            for occurrence in Recurrence.occurrences(of: task, in: window) {
                let done = task.rrule == nil
                    ? task.isCompleted
                    : completions.contains(
                        CompletedOccurrence(taskID: task.id, occurrence: occurrence)
                    )
                items.append(
                    DayItem(task: task, occurrence: occurrence, isCompleted: done)
                )
            }
        }
        return items.sorted { $0.occurrence < $1.occurrence }
    }

    /// Строки выбранного дня — то, что показывает режим «День».
    public var visibleItems: [DayItem] {
        let calendar = Calendar.current
        guard scale != .day else { return items }
        return items.filter { calendar.isDate($0.occurrence, inSameDayAs: day) }
    }

    /// Разложенные по дням — для недели и для сетки месяца.
    public var itemsByDay: [Date: [DayItem]] {
        let calendar = Calendar.current
        return Dictionary(grouping: items) { calendar.startOfDay(for: $0.occurrence) }
    }

    public var unfinishedCount: Int {
        visibleItems.filter { !$0.isCompleted }.count
    }

    /// The next thing that has not happened yet — the one the screen leads with.
    ///
    /// On a day that is not today there is no "next": the whole day is ahead or
    /// behind, and singling one out would be arbitrary.
    public var nextItem: DayItem? {
        guard Calendar.current.isDateInToday(day) else { return nil }
        let now = Date()
        let unfinished = visibleItems.filter { !$0.isCompleted }

        // The next thing with a time on it. An all-day task is stored at
        // midnight, so by the clock it is always in the past — it is not
        // "next", it is "today".
        if let timed = unfinished.first(where: { !$0.task.isAllDay && $0.occurrence >= now }) {
            return timed
        }

        // Nothing left with a time: whatever is on for the day will do.
        return unfinished.first(where: \.task.isAllDay)
    }

    public func onAppear() {
        restartTaskObservation()
        guard supportObservation == nil else { return }
        supportObservation = Task {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await self.observeCategories() }
                group.addTask { await self.observeNotices() }
                group.addTask { await self.observePacking() }
                group.addTask { await self.observeAlerts() }
                group.addTask { await self.observePeople() }
            }
        }
    }

    public func onDisappear() {
        taskObservation?.cancel()
        completionObservation?.cancel()
        supportObservation?.cancel()
        taskObservation = nil
        completionObservation = nil
        supportObservation = nil
    }

    private func restartTaskObservation() {
        taskObservation?.cancel()
        let window = range

        // The ticked-off instants follow the same window, so they are restarted
        // with it rather than once at the start: a month moved on would
        // otherwise be read against last month's answers.
        completionObservation?.cancel()
        completionObservation = Task { [environment, window] in
            do {
                for try await value in environment.tasks.observeCompletions(
                    from: window.lowerBound, to: window.upperBound
                ) {
                    self.completions = value
                }
            } catch {
                Log.database.error(
                    "completion observation ended: \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        taskObservation = Task { [environment, window] in
            do {
                for try await value in environment.tasks.tasksTouching(
                    from: window.lowerBound, to: window.upperBound
                ) {
                    self.tasks = value
                }
            } catch {
                // An observation that stops is a local database problem, not a
                // network one. Nothing the person can act on.
                Log.database.error("day observation ended: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func observeCategories() async {
        do {
            for try await value in environment.categories.observeAll() {
                self.categories = Dictionary(uniqueKeysWithValues: value.map { ($0.id, $0) })
            }
        } catch {
            Log.database.error("category observation ended: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func observeAlerts() async {
        do {
            for try await value in environment.reminders.observeTasksWithAlerts() {
                self.alerts = value
            }
        } catch {
            Log.database.error("alert observation ended: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func observePeople() async {
        do {
            for try await value in environment.household.people() {
                self.people = value
            }
        } catch {
            Log.database.error("people observation ended: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func observePacking() async {
        do {
            for try await value in environment.subtasks.observeProgress() {
                self.packing = value
            }
        } catch {
            Log.database.error("packing observation ended: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func observeNotices() async {
        do {
            for try await value in environment.supersededEdits.observeOpen() {
                self.notices = value
            }
        } catch {
            Log.database.error("notice observation ended: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Actions

    /// Ticking a line off. Both kinds stay where they are, crossed out.
    public func toggleCompleted(_ item: DayItem) {
        do {
            if item.isRepeating {
                try environment.tasks.setCompleted(
                    item.task, occurrence: item.occurrence, !item.isCompleted
                )
            } else {
                try environment.tasks.setCompleted(item.task, !item.isCompleted)
            }
        } catch {
            Log.database.error("could not save: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Deleting one instant of a repeat, rather than the whole series.
    public func skip(_ item: DayItem) {
        do {
            try environment.tasks.skip(item.task, occurrence: item.occurrence)
        } catch {
            Log.database.error("could not skip: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func delete(_ item: DayItem) {
        do {
            try environment.tasks.delete(item.task)
        } catch {
            Log.database.error("could not delete: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func restore(_ notice: SupersededEdit) {
        do {
            try environment.supersededEdits.restore(notice, using: environment.tasks)
        } catch {
            Log.database.error("could not restore: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func dismiss(_ notice: SupersededEdit) {
        localWrite("dismissing a replaced-edit notice") {
            try environment.supersededEdits.dismiss(notice)
        }
    }
}
