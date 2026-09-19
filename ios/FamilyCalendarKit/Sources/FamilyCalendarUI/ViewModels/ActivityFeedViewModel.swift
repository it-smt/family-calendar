import FamilyCalendarKit
import Foundation
import OSLog
import Observation

/// Лента изменений.
///
/// Фразы и группировка по дням считаются здесь, а не в теле экрана: раньше
/// `Dictionary(grouping:)` с сортировкой выполнялся на каждое обновление
/// внутри `body`, то есть при любом чужом изменении и при каждой перерисовке.
/// На сотне строк это пыль, но место этой работе не там.
@MainActor
@Observable
public final class ActivityFeedViewModel {
    /// Одна строка ленты, уже собранная: фраза, цвет и буква.
    public struct Line: Identifiable, Sendable {
        public let id: UUID
        public let sentence: String
        public let at: Date
        public let colorHex: String
        public let initial: String
        public let icon: String
    }

    /// Один день ленты.
    public struct Day: Identifiable, Sendable {
        public let day: Date
        public let title: String
        public let lines: [Line]

        public var id: Date { day }
    }

    public private(set) var days: [Day] = []
    public private(set) var mayHaveMore = false
    public private(set) var isEmpty = true

    private let environment: AppEnvironment
    private var observation: Task<Void, Never>?
    private var limit = 100

    public init(environment: AppEnvironment) {
        self.environment = environment
    }

    public func onAppear() {
        guard observation == nil else { return }
        restart()
    }

    public func onDisappear() {
        observation?.cancel()
        observation = nil
    }

    /// Ещё сто. Старое не выбрасывается — просто спрашивается больше.
    public func showMore() {
        limit += 100
        restart()
    }

    private func restart() {
        observation?.cancel()
        observation = Task { [environment, limit] in
            do {
                for try await snapshot in environment.activityFeed.observe(limit: limit) {
                    self.rebuild(from: snapshot)
                }
            } catch {
                Log.database.error(
                    "feed observation ended: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    private func rebuild(from snapshot: FeedSnapshot) {
        let calendar = Calendar.current
        let mine = environment.currentUserID

        let lines = snapshot.entries.map { entry -> (day: Date, line: Line) in
            let person = snapshot.people[entry.actorID]
            return (
                calendar.startOfDay(for: entry.createdAt),
                Line(
                    id: entry.id,
                    sentence: Self.sentence(for: entry, mine: mine, person: person),
                    at: entry.createdAt,
                    colorHex: entry.actorID == mine
                        ? Self.ownColour
                        : person?.color ?? Self.unknownColour,
                    initial: Self.initial(for: entry.actorID, mine: mine, person: person),
                    icon: Self.icon(for: entry.action)
                )
            )
        }

        days = Dictionary(grouping: lines, by: \.day)
            .map { day, group in
                Day(
                    day: day,
                    title: Self.dayTitle(day, calendar: calendar),
                    lines: group.map(\.line).sorted { $0.at > $1.at }
                )
            }
            .sorted { $0.day > $1.day }

        isEmpty = snapshot.entries.isEmpty
        mayHaveMore = snapshot.mayHaveMore
    }

    // MARK: Слова

    static let ownColour = "#9A4BC9"
    static let unknownColour = "#8E99AB"

    static func initial(for actor: UUID, mine: UUID, person: User?) -> String {
        let name = person?.displayName ?? (actor == mine ? "Я" : "?")
        return String(name.prefix(1)).uppercased()
    }

    static func icon(for action: String) -> String {
        switch action {
        case "created": "plus"
        case "updated": "pencil"
        case "completed": "checkmark"
        case "deleted": "trash"
        default: "circle"
        }
    }

    static func dayTitle(_ day: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(day) { return "Сегодня" }
        if calendar.isDateInYesterday(day) { return "Вчера" }
        return day.formatted(.dateTime.day().month(.wide))
    }

    static func sentence(for entry: ActivityEntry, mine: UUID, person: User?) -> String {
        let who = entry.actorID == mine ? "Ты" : person?.displayName ?? "Кто-то"

        let what = switch entry.entityType {
        case "task": "задачу"
        case "subtask": "пункт"
        case "shopping_item": "покупку"
        default: entry.entityType
        }

        // Прошедшее время согласуется с родом, а род мы не знаем. Поэтому
        // безличные формы: «Аня — добавила» звучало бы лучше, но «Аня —
        // добавил» звучало бы плохо, а угадать нельзя.
        let verb = switch entry.action {
        case "created": "добавил(а)"
        case "updated": "изменил(а)"
        case "completed": "выполнил(а)"
        case "deleted": "удалил(а)"
        default: entry.action
        }

        let label = entry.summary.isEmpty ? what : "\(what) «\(entry.summary)»"
        return "\(who) \(verb) \(label)"
    }
}
