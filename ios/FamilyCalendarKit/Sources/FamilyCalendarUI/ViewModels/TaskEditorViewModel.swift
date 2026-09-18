import Foundation
import FamilyCalendarKit
import Observation

/// Creating and editing one task.
///
/// The editor holds a draft and saves it on demand. Saving writes to the local
/// database and returns — it never reports a network result, because there is
/// nothing to report: the change is safe the moment it is written.
@MainActor
@Observable
public final class TaskEditorViewModel {
    public enum Mode: Sendable {
        case creating
        case editing(CalendarTask)
    }

    public var title: String = ""
    public var notes: String = ""
    public var hasTime: Bool = false
    public var startsAt: Date = Date()
    public var durationMinutes: Int = 60
    public var isAllDay: Bool = false
    public var categoryID: UUID?
    public var assigneeID: UUID?
    public var travelMode: TravelMode = .none
    public var locationName: String = ""

    public private(set) var subtasks: [Subtask] = []
    public private(set) var categories: [Category] = []
    public private(set) var templates: [PackingTemplate] = []

    public var newSubtaskTitle: String = ""

    private let environment: AppEnvironment
    private let mode: Mode
    private var observation: Task<Void, Never>?

    public init(environment: AppEnvironment, mode: Mode, day: Date = Date()) {
        self.environment = environment
        self.mode = mode

        switch mode {
        case .creating:
            startsAt = Self.defaultTime(on: day)
        case .editing(let task):
            title = task.title
            notes = task.notes ?? ""
            hasTime = task.startsAt != nil
            startsAt = task.startsAt ?? Self.defaultTime(on: day)
            durationMinutes = task.durationMinutes ?? 60
            isAllDay = task.isAllDay
            categoryID = task.categoryID
            assigneeID = task.assigneeID
            travelMode = task.travelMode
            locationName = task.locationName ?? ""
        }
    }

    public var isEditing: Bool {
        if case .editing = mode { return true }
        return false
    }

    public var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var editedTask: CalendarTask? {
        if case .editing(let task) = mode { return task }
        return nil
    }

    private static func defaultTime(on day: Date) -> Date {
        let calendar = Calendar.current
        let now = Date()
        // The chosen day, at the next round hour.
        var components = calendar.dateComponents([.year, .month, .day], from: day)
        components.hour = calendar.component(.hour, from: now) + 1
        components.minute = 0
        return calendar.date(from: components) ?? day
    }

    public func onAppear() {
        guard observation == nil else { return }
        observation = Task {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await self.observeCategories() }
                if case .editing(let task) = self.mode {
                    group.addTask { await self.observeSubtasks(of: task.id) }
                }
            }
        }
    }

    public func onDisappear() {
        observation?.cancel()
        observation = nil
    }

    private func observeCategories() async {
        do {
            for try await value in environment.categories.observeAll() {
                self.categories = value
            }
        } catch {
            Log.database.error("category observation ended: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func observeSubtasks(of taskID: UUID) async {
        do {
            for try await value in environment.subtasks.observe(taskID: taskID) {
                self.subtasks = value
            }
        } catch {
            Log.database.error("subtask observation ended: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Saving

    @discardableResult
    public func save() -> CalendarTask? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        do {
            switch mode {
            case .creating:
                let task = CalendarTask(
                    householdID: environment.householdID,
                    title: trimmed,
                    notes: notes.isEmpty ? nil : notes,
                    startsAt: hasTime ? startsAt : nil,
                    durationMinutes: hasTime ? durationMinutes : nil,
                    isAllDay: isAllDay,
                    locationName: locationName.isEmpty ? nil : locationName,
                    assigneeID: assigneeID,
                    createdBy: environment.currentUserID,
                    categoryID: categoryID,
                    travelMode: travelMode
                )
                return try environment.tasks.create(task)

            case .editing(let task):
                try environment.tasks.update(task) { draft in
                    draft.title = trimmed
                    draft.notes = notes.isEmpty ? nil : notes
                    draft.startsAt = hasTime ? startsAt : nil
                    draft.durationMinutes = hasTime ? durationMinutes : nil
                    draft.isAllDay = isAllDay
                    draft.locationName = locationName.isEmpty ? nil : locationName
                    draft.assigneeID = assigneeID
                    draft.categoryID = categoryID
                    draft.travelMode = travelMode
                }
                return task
            }
        } catch {
            Log.database.error("could not save the task: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: Subtasks

    public func addSubtask() {
        let trimmed = newSubtaskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, case .editing(let task) = mode else { return }
        do {
            try environment.subtasks.add(to: task.id, title: trimmed)
            newSubtaskTitle = ""
        } catch {
            Log.database.error("could not add a subtask: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func toggle(_ subtask: Subtask) {
        try? environment.subtasks.setDone(subtask, !subtask.isDone)
    }

    public func delete(_ subtask: Subtask) {
        try? environment.subtasks.delete(subtask)
    }
}
