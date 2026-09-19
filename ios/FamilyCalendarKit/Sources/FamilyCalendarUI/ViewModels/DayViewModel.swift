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

    public var id: String {
        "\(task.id.uuidString)@\(Timestamp.string(from: occurrence))"
    }

    public var isRepeating: Bool { task.rrule != nil }
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

    public var day: Date {
        didSet {
            guard !Calendar.current.isDate(day, inSameDayAs: oldValue) else { return }
            restartTaskObservation()
        }
    }

    /// Filters. Both are plain local state — filtering never goes near a query
    /// the network could be involved in.
    public var categoryFilter: UUID? { didSet { restartTaskObservation() } }
    public var assigneeFilter: UUID? { didSet { restartTaskObservation() } }

    private let environment: AppEnvironment
    private var taskObservation: Task<Void, Never>?
    private var supportObservation: Task<Void, Never>?

    public init(environment: AppEnvironment, day: Date = Date()) {
        self.environment = environment
        self.day = day
    }

    /// Today's lines: every task that falls on this day, repeats expanded.
    public var visibleItems: [DayItem] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }

        var items: [DayItem] = []
        for task in tasks {
            if let categoryFilter, task.categoryID != categoryFilter { continue }
            if let assigneeFilter, task.assigneeID != assigneeFilter { continue }
            for occurrence in Recurrence.occurrences(of: task, in: start..<end) {
                items.append(DayItem(task: task, occurrence: occurrence))
            }
        }
        return items.sorted { $0.occurrence < $1.occurrence }
    }

    public var unfinishedCount: Int {
        visibleItems.filter { !$0.task.isCompleted }.count
    }

    /// The next thing that has not happened yet — the one the screen leads with.
    ///
    /// On a day that is not today there is no "next": the whole day is ahead or
    /// behind, and singling one out would be arbitrary.
    public var nextItem: DayItem? {
        guard Calendar.current.isDateInToday(day) else { return nil }
        let now = Date()
        let unfinished = visibleItems.filter { !$0.task.isCompleted }

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
        supportObservation?.cancel()
        taskObservation = nil
        supportObservation = nil
    }

    private func restartTaskObservation() {
        taskObservation?.cancel()
        taskObservation = Task { [environment, day] in
            do {
                for try await value in environment.tasks.tasksTouching(day) {
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

    /// Ticking a line off.
    ///
    /// A repeat has one row and many instants, so "done" for one Tuesday is
    /// recorded by striking that instant out of the rule — the line goes away
    /// rather than going grey. A task that happens once is marked completed
    /// and stays, crossed out, where it was.
    public func toggleCompleted(_ item: DayItem) {
        do {
            if item.isRepeating {
                try environment.tasks.skip(item.task, occurrence: item.occurrence)
            } else {
                try environment.tasks.setCompleted(item.task, !item.task.isCompleted)
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
