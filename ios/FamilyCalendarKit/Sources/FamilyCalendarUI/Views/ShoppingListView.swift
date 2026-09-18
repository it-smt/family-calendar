import FamilyCalendarKit
import SwiftUI

/// The shopping list. Quick to add to, because that is the only thing anyone
/// does with it while standing in a kitchen.
public struct ShoppingListView: View {
    @State private var items: [ShoppingItem] = []
    @State private var draft: String = ""
    @State private var observation: Task<Void, Never>?
    @FocusState private var addingFocused: Bool

    private let environment: AppEnvironment

    public init(environment: AppEnvironment) {
        self.environment = environment
    }

    public var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Image(systemName: "plus.circle.fill").foregroundStyle(.secondary)
                        TextField("Add something", text: $draft)
                            .focused($addingFocused)
                            .onSubmit(add)
                            .submitLabel(.done)
                    }
                }

                ForEach(items) { item in
                    Button {
                        try? environment.shopping.setBought(item, !item.isBought)
                    } label: {
                        HStack {
                            Image(systemName: item.isBought ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(item.isBought ? .green : .secondary)
                            Text(item.title)
                                .strikethrough(item.isBought)
                                .foregroundStyle(item.isBought ? .secondary : .primary)
                            Spacer()
                            if let quantity = item.quantity, !quantity.isEmpty {
                                Text(quantity).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .swipeActions {
                        Button(role: .destructive) {
                            try? environment.shopping.delete(item)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
            .navigationTitle("Shopping")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    SyncIndicator(status: environment.status)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Clear bought") {
                        try? environment.shopping.clearBought()
                    }
                    .disabled(!items.contains(where: \.isBought))
                }
            }
            .task {
                guard observation == nil else { return }
                observation = Task {
                    do {
                        for try await value in environment.shopping.observe() {
                            items = value
                        }
                    } catch {
                        Log.database.error("shopping observation ended: \(error.localizedDescription, privacy: .public)")
                    }
                }
            }
            .onDisappear {
                observation?.cancel()
                observation = nil
            }
        }
    }

    private func add() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try? environment.shopping.add(title: trimmed)
        draft = ""
        // Stay in the field: people add three things, not one.
        addingFocused = true
    }
}
