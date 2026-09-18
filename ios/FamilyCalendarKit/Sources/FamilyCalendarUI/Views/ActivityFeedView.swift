import FamilyCalendarKit
import SwiftUI

/// "She moved the doctor to 16:00."
///
/// The sentence is built here, not stored. The server keeps the verb and the
/// label; the language, and which of the two people is "you", are known only on
/// the device.
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
            List {
                if entries.isEmpty {
                    ContentUnavailableView(
                        "Nothing yet",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("Changes either of you make will show up here.")
                    )
                } else {
                    ForEach(entries) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(sentence(for: entry))
                                .font(.subheadline)
                            Text(entry.createdAt, format: .relative(presentation: .named))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .navigationTitle("Changes")
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
                entries = value
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

    private func sentence(for entry: ActivityEntry) -> String {
        let who = entry.actorID == environment.currentUserID
            ? "You"
            : people[entry.actorID]?.displayName ?? "Someone"

        let what: String
        switch entry.entityType {
        case "task": what = "task"
        case "subtask": what = "item"
        case "shopping_item": what = "shopping item"
        default: what = entry.entityType
        }

        let verb: String
        switch entry.action {
        case "created": verb = "added"
        case "updated": verb = "changed"
        case "completed": verb = "finished"
        case "deleted": verb = "removed"
        default: verb = entry.action
        }

        let label = entry.summary.isEmpty ? what : "\(what) “\(entry.summary)”"
        return "\(who) \(verb) the \(label)"
    }
}
