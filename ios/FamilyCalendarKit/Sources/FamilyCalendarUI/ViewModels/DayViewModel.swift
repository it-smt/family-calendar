import Foundation
import FamilyCalendarKit
import Observation

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

    public var visibleTasks: [CalendarTask] {
        tasks.filter { task in
            if let categoryFilter, task.categoryID != categoryFilter { return false }
            if let assigneeFilter, task.assigneeID != assigneeFilter { return false }
            return true
        }
    }

    public var unfinishedCount: Int {
        visibleTasks.filter { !$0.isCompleted }.count
    }

    public func onAppear() {
        restartTaskObservation()
        guard supportObservation == nil else { return }
        supportObservation = Task {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await self.observeCategories() }
                group.addTask { await self.observeNotices() }
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
                for try await value in environment.tasks.tasksOnDay(day) {
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

    public func toggleCompleted(_ task: CalendarTask) {
        do {
            try environment.tasks.setCompleted(task, !task.isCompleted)
        } catch {
            Log.database.error("could not save: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func delete(_ task: CalendarTask) {
        do {
            try environment.tasks.delete(task)
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
        try? environment.supersededEdits.dismiss(notice)
    }
}
