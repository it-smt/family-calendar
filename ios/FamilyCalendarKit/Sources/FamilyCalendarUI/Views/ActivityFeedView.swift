import FamilyCalendarKit
import OSLog
import SwiftUI

/// «Слава перенёс врача на 16:00».
///
/// Фраза собирается здесь, а не хранится. Сервер держит глагол и ярлык; кто из
/// двоих «ты» и на каком это языке — знает только телефон.
public struct ActivityFeedView: View {
    @State private var entries: [ActivityEntry] = []
    @State private var people: [UUID: User] = [:]
    @State private var observation: Task<Void, Never>?

    private let environment: AppEnvironment

    public init(environment: AppEnvironment) {
        self.environment = environment
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Theme.ScreenHeader(
                    "Изменения",
                    subtitle: entries.isEmpty ? nil : "Кто что трогал",
                    gradient: Theme.feedGradient
                )

                if entries.isEmpty {
                    empty
                } else {
                    days
                }
            }
        }
        .headeredScreen()
        .task {
            guard observation == nil else { return }
            observation = Task {
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { await observeEntries() }
                    group.addTask { await observePeople() }
                }
            }
        }
        .onDisappear {
            observation?.cancel()
            observation = nil
        }
    }

    // MARK: Лента

    /// Записи, разложенные по дням, свежий день сверху.
    ///
    /// Тип, а не кортеж: по кортежу `ForEach` нечем адресоваться.
    struct Day: Identifiable {
        let day: Date
        let entries: [ActivityEntry]

        var id: Date { day }
    }

    private var grouped: [Day] {
        let calendar = Calendar.current
        let buckets = Dictionary(grouping: entries) { calendar.startOfDay(for: $0.createdAt) }
        return buckets
            .map { Day(day: $0.key, entries: $0.value.sorted { $0.createdAt > $1.createdAt }) }
            .sorted { $0.day > $1.day }
    }

    private var days: some View {
        LazyVStack(alignment: .leading, spacing: 18) {
            ForEach(grouped) { group in
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel(dayLabel(group.day))
                    ForEach(group.entries) { entry in
                        row(entry)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 20)
        .padding(.bottom, 28)
    }

    private func row(_ entry: ActivityEntry) -> some View {
        let accent = colour(for: entry.actorID)
        return HStack(alignment: .top, spacing: 12) {
            // Инициал вместо аватара: фотографий у нас нет, а две буквы на
            // цветном кружке различаются с той же одной секунды.
            Text(initial(for: entry.actorID))
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(Circle().fill(accent))

            VStack(alignment: .leading, spacing: 3) {
                Text(sentence(for: entry))
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Image(systemName: icon(for: entry.action))
                        .font(.caption2)
                    Text(entry.createdAt, style: .time)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .card(tint: accent)
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
            Text("Пока ничего")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            Text("Здесь появится всё, что меняет каждый из вас")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
        .card()
        .padding(.horizontal, 16)
        .padding(.top, 28)
    }

    // MARK: Наблюдение

    private func observeEntries() async {
        do {
            for try await value in environment.activityFeed.observe() {
                withAnimation(.snappy) { entries = value }
            }
        } catch {
            Log.database.error("feed observation ended: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func observePeople() async {
        do {
            for try await value in environment.activityFeed.people() {
                people = value
            }
        } catch {
            Log.database.error("people observation ended: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Слова

    private func colour(for actor: UUID) -> Color {
        actor == environment.currentUserID
            ? Theme.feedGradient.to
            : people[actor].map { Color(hex: $0.color) } ?? Theme.unlabelled
    }

    private func initial(for actor: UUID) -> String {
        let name = actor == environment.currentUserID
            ? people[actor]?.displayName ?? "Я"
            : people[actor]?.displayName ?? "?"
        return String(name.prefix(1)).uppercased()
    }

    private func icon(for action: String) -> String {
        switch action {
        case "created": "plus"
        case "updated": "pencil"
        case "completed": "checkmark"
        case "deleted": "trash"
        default: "circle"
        }
    }

    private func dayLabel(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Сегодня" }
        if calendar.isDateInYesterday(day) { return "Вчера" }
        return day.formatted(.dateTime.day().month(.wide))
    }

    private func sentence(for entry: ActivityEntry) -> String {
        let mine = entry.actorID == environment.currentUserID
        let who = mine ? "Ты" : people[entry.actorID]?.displayName ?? "Кто-то"

        let what = switch entry.entityType {
        case "task": "задачу"
        case "subtask": "пункт"
        case "shopping_item": "покупку"
        default: entry.entityType
        }

        // Прошедшее время согласуется с родом, а род мы не знаем. Поэтому
        // безличные формы: «Аня — добавила» звучало бы лучше, но «Аня — добавил»
        // звучало бы плохо, а угадать нельзя.
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
