import FamilyCalendarKit
import Foundation
import OSLog
import Observation

/// Место, привязанное к точке на карте.
public struct PinnedPlace: Sendable, Equatable {
    public let name: String
    public let latitude: Double
    public let longitude: Double

    public init(name: String, latitude: Double, longitude: Double) {
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
    }
}

/// Повторы, которые действительно заводят: не конструктор RFC 5545, а шесть
/// правил, которыми живёт семья.
///
/// Движок понимает весь стандарт — и проверен против `python-dateutil` на
/// четырёхстах случайных правилах. Но экран, на котором можно собрать
/// «третий четверг каждого второго месяца», нужен примерно никому, а стоит
/// дорого. Правило, пришедшее откуда-то ещё и не похожее ни на одно из этих,
/// показывается как «своё» и сохраняется нетронутым.
public enum RepeatRule: String, CaseIterable, Sendable, Identifiable {
    case never, daily, weekdays, weekly, biweekly, monthly, yearly, custom

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .never: "Не повторять"
        case .daily: "Каждый день"
        case .weekdays: "По будням"
        case .weekly: "Каждую неделю"
        case .biweekly: "Раз в две недели"
        case .monthly: "Каждый месяц"
        case .yearly: "Каждый год"
        case .custom: "Своё правило"
        }
    }

    /// Без префикса `RRULE:` — так это лежит в колонке и так это читает и
    /// сервер, и движок.
    public var rrule: String? {
        switch self {
        case .never, .custom: nil
        case .daily: "FREQ=DAILY"
        case .weekdays: "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR"
        case .weekly: "FREQ=WEEKLY"
        case .biweekly: "FREQ=WEEKLY;INTERVAL=2"
        case .monthly: "FREQ=MONTHLY"
        case .yearly: "FREQ=YEARLY"
        }
    }

    /// Те, что показываются в списке: «своё» туда не попадает, его нельзя
    /// выбрать — только унаследовать.
    public static var offered: [RepeatRule] {
        allCases.filter { $0 != .custom }
    }

    public static func matching(_ rrule: String?) -> RepeatRule {
        guard let rrule, !rrule.isEmpty else { return .never }
        let wanted = rrule.uppercased()
        return offered.first { $0.rrule?.uppercased() == wanted } ?? .custom
    }
}

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
    /// Every task has a day. The only question is whether it also has a time.
    ///
    /// There used to be a third state — no date at all — and a task in it was
    /// saved correctly and then shown by nothing: the day list asks for the
    /// tasks whose `starts_at` falls inside the day, and a NULL falls inside
    /// no day. Removing the state is the fix; a screen must not be able to
    /// make a row that no screen can show.
    public var startsAt: Date = Date()
    public var durationMinutes: Int = 60
    public var isAllDay: Bool = false
    public var categoryID: UUID?
    public var assigneeID: UUID?

    /// Правило повтора, как оно лежит в колонке.
    public private(set) var rrule: String?

    /// Что выбрано в списке. «Своё» выбрать нельзя — оно только показывается,
    /// и переключение на что угодно другое его заменяет.
    public var repeatRule: RepeatRule {
        get { RepeatRule.matching(rrule) }
        set {
            guard newValue != .custom else { return }
            rrule = newValue.rrule
        }
    }
    public var travelMode: TravelMode = .none
    public var locationName: String = ""

    /// Место, выбранное на карте.
    ///
    /// Координаты засчитываются только пока название совпадает с тем, под
    /// которым их выбрали: «Поликлиника» и «Поликлиника 3» — разные места, а
    /// точка осталась бы старой и молча увела бы «когда выходить» не туда.
    public private(set) var pinned: PinnedPlace?

    public var isPinned: Bool {
        guard let pinned else { return false }
        return pinned.name == locationName
    }

    public func pin(_ place: PinnedPlace) {
        pinned = place
        locationName = place.name
    }

    public private(set) var subtasks: [Subtask] = []
    public private(set) var reminders: [Reminder] = []
    public private(set) var categories: [TaskCategory] = []
    public private(set) var templates: [PackingTemplate] = []
    public private(set) var people: [User] = []

    public var newSubtaskTitle: String = ""

    private let environment: AppEnvironment
    private let mode: Mode
    private var observation: Task<Void, Never>?

    /// The task's identifier, known before the task exists.
    ///
    /// A list of things to bring can then be attached to a new task straight
    /// away: the rows point at this, and the task is saved under the same
    /// identifier a moment later. Making people save first and come back was
    /// never a rule of the data — only of the screen.
    private let taskID: UUID

    public init(environment: AppEnvironment, mode: Mode, day: Date = Date()) {
        self.environment = environment
        self.mode = mode

        switch mode {
        case .creating:
            taskID = UUID()
            startsAt = Self.defaultTime(on: day)
        case .editing(let task):
            taskID = task.id
            title = task.title
            notes = task.notes ?? ""
            startsAt = task.startsAt ?? Self.defaultTime(on: day)
            durationMinutes = task.durationMinutes ?? 60
            // A row from before every task had a date reads as all-day, which
            // is what the repair migration makes of it too.
            isAllDay = task.isAllDay || task.startsAt == nil
            categoryID = task.categoryID
            assigneeID = task.assigneeID
            rrule = task.rrule
            travelMode = task.travelMode
            locationName = task.locationName ?? ""
            if let name = task.locationName, let latitude = task.latitude,
                let longitude = task.longitude
            {
                pinned = PinnedPlace(name: name, latitude: latitude, longitude: longitude)
            }
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
        // Clamped, or a task added at half past eleven would default to
        // midnight — which is the next day, and therefore not the day the
        // person is looking at.
        components.hour = min(calendar.component(.hour, from: now) + 1, 23)
        components.minute = 0
        return calendar.date(from: components) ?? day
    }

    public func onAppear() {
        guard observation == nil else { return }
        observation = Task {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await self.observeCategories() }
                group.addTask { await self.observePeople() }
                if case .editing(let task) = self.mode {
                    group.addTask { await self.observeSubtasks(of: task.id) }
                    group.addTask { await self.observeReminders(of: task.id) }
                }
                group.addTask { await self.observeTemplates() }
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

    private func observePeople() async {
        do {
            for try await value in environment.household.people() {
                self.people = value.values.sorted { $0.displayName < $1.displayName }
            }
        } catch {
            Log.database.error("people observation ended: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func observeReminders(of taskID: UUID) async {
        do {
            for try await value in environment.reminders.observe(taskID: taskID) {
                self.reminders = value.sorted { $0.offsetMinutes > $1.offsetMinutes }
            }
        } catch {
            Log.database.error("reminder observation ended: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func observeTemplates() async {
        do {
            for try await value in environment.packingTemplates.observe() {
                self.templates = value
            }
        } catch {
            Log.database.error("template observation ended: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// One tap turns "бассейн" into four things to tick off.
    public func apply(_ template: PackingTemplate) {
        add(titles: template.items)
    }

    /// Where a new item goes: into the database when the task is already
    /// there, into this object when it is not. Saving writes the difference.
    private func add(titles: [String]) {
        guard !titles.isEmpty else { return }

        guard isEditing else {
            let start = subtasks.count
            subtasks.append(
                contentsOf: titles.enumerated().map { offset, title in
                    Subtask(
                        householdID: environment.householdID,
                        taskID: taskID,
                        title: title,
                        sortOrder: start + offset
                    )
                }
            )
            return
        }

        do {
            for title in titles {
                try environment.subtasks.add(to: taskID, title: title)
            }
        } catch {
            Log.database.error("could not add to the list: \(error.localizedDescription, privacy: .public)")
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

        // An all-day task is stored at the start of its day rather than with no
        // time at all, so the day list finds it the same way it finds every
        // other task, and it sorts to the top of the day where it belongs.
        let when = isAllDay ? Calendar.current.startOfDay(for: startsAt) : startsAt

        do {
            switch mode {
            case .creating:
                let task = CalendarTask(
                    id: taskID,
                    householdID: environment.householdID,
                    title: trimmed,
                    notes: notes.isEmpty ? nil : notes,
                    startsAt: when,
                    durationMinutes: isAllDay ? nil : durationMinutes,
                    isAllDay: isAllDay,
                    locationName: locationName.isEmpty ? nil : locationName,
                    latitude: isPinned ? pinned?.latitude : nil,
                    longitude: isPinned ? pinned?.longitude : nil,
                    rrule: rrule,
                    assigneeID: assigneeID,
                    createdBy: environment.currentUserID,
                    categoryID: categoryID,
                    travelMode: travelMode
                )
                let saved = try environment.tasks.create(task)
                // After the task, never before: the rows point at it, and the
                // database will not hold a child whose parent is not there.
                try environment.subtasks.insert(subtasks)
                try environment.reminders.insert(reminders)
                return saved

            case .editing(let task):
                try environment.tasks.update(task) { draft in
                    draft.title = trimmed
                    draft.notes = notes.isEmpty ? nil : notes
                    draft.startsAt = when
                    draft.durationMinutes = isAllDay ? nil : durationMinutes
                    draft.isAllDay = isAllDay
                    draft.rrule = rrule
                    draft.locationName = locationName.isEmpty ? nil : locationName
                    draft.latitude = isPinned ? pinned?.latitude : nil
                    draft.longitude = isPinned ? pinned?.longitude : nil
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

    // MARK: Напоминания

    /// Whether "when to leave" is worth offering: it needs somewhere to go and
    /// a way of getting there, and without both it is an alert about nothing.
    public var canRemindToLeave: Bool {
        travelMode != .none && isPinned && !isAllDay
    }

    public func addReminder(offsetMinutes: Int, kind: ReminderKind = .fixed) {
        // The same alert twice would ring twice.
        guard !reminders.contains(where: {
            $0.offsetMinutes == offsetMinutes && $0.kind == kind
        }) else { return }

        let reminder = environment.reminders.make(
            for: taskID, offsetMinutes: offsetMinutes, kind: kind
        )

        guard isEditing else {
            reminders.append(reminder)
            reminders.sort { $0.offsetMinutes > $1.offsetMinutes }
            return
        }

        do {
            try environment.reminders.insert([reminder])
        } catch {
            Log.database.error("could not add a reminder: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func delete(_ reminder: Reminder) {
        guard isEditing else {
            reminders.removeAll { $0.id == reminder.id }
            return
        }
        localWrite("deleting a reminder") {
            try environment.reminders.delete(reminder)
        }
    }

    // MARK: Subtasks

    public func addSubtask() {
        let trimmed = newSubtaskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        add(titles: [trimmed])
        newSubtaskTitle = ""
    }

    public func toggle(_ subtask: Subtask) {
        guard isEditing else {
            if let index = subtasks.firstIndex(where: { $0.id == subtask.id }) {
                subtasks[index].isDone.toggle()
            }
            return
        }
        localWrite("marking a subtask") {
            try environment.subtasks.setDone(subtask, !subtask.isDone)
        }
    }

    public func delete(_ subtask: Subtask) {
        guard isEditing else {
            subtasks.removeAll { $0.id == subtask.id }
            return
        }
        localWrite("deleting a subtask") {
            try environment.subtasks.delete(subtask)
        }
    }
}
