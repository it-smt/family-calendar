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
        NavigationStack {
            ScrollView {
                VStack(spacing: 10) {
                    if entries.isEmpty {
                        VStack(spacing: 6) {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.largeTitle)
                                .foregroundStyle(.secondary)
                            Text("Пока ничего")
                                .font(.subheadline)
                            Text("Здесь появится всё, что меняет каждый из вас")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                        .card()
                    }

                    ForEach(entries) { entry in
                        HStack(alignment: .top, spacing: 10) {
                            Circle()
                                .fill(colour(for: entry.actorID))
                                .frame(width: 8, height: 8)
                                .padding(.top, 6)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(sentence(for: entry))
                                    .font(.subheadline)
                                Text(entry.createdAt, format: .relative(presentation: .named))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .card()
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .themedScreen()
            .navigationTitle("Изменения")
            .navigationBarTitleDisplayMode(.inline)
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
    }

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

    private func colour(for actor: UUID) -> Color {
        actor == environment.currentUserID
            ? .accentColor
            : people[actor].map { Color(hex: $0.color) } ?? .secondary
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
