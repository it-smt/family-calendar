import FamilyCalendarKit
import OSLog
import SwiftUI

/// Покупки. Быстро добавить — единственное, что с этим экраном делают,
/// стоя на кухне, поэтому поле ввода вверху и клавиатура не закрывается.
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
            ScrollView {
                VStack(spacing: 10) {
                    HStack(spacing: 10) {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                        TextField("Что купить", text: $draft)
                            .focused($addingFocused)
                            .onSubmit(add)
                            .submitLabel(.done)
                    }
                    .card(emphasised: true)

                    if items.isEmpty {
                        Text("Список пуст")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 36)
                            .card()
                    }

                    ForEach(items) { item in
                        Button {
                            withAnimation(.snappy) {
                                try? environment.shopping.setBought(item, !item.isBought)
                            }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: item.isBought ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(item.isBought ? .green : .secondary)
                                    .symbolEffect(.bounce, value: item.isBought)
                                Text(item.title)
                                    .strikethrough(item.isBought)
                                    .foregroundStyle(item.isBought ? .secondary : .primary)
                                Spacer()
                                if let quantity = item.quantity, !quantity.isEmpty {
                                    Text(quantity)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .card()
                        .contextMenu {
                            Button(role: .destructive) {
                                try? environment.shopping.delete(item)
                            } label: {
                                Label("Удалить", systemImage: "trash")
                            }
                        }
                        .transition(.opacity.combined(with: .scale(scale: 0.97)))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .themedScreen()
            .navigationTitle("Покупки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    SyncIndicator(status: environment.status)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Убрать купленное") {
                        withAnimation(.snappy) { try? environment.shopping.clearBought() }
                    }
                    .font(.caption)
                    .disabled(!items.contains(where: \.isBought))
                }
            }
            .task {
                guard observation == nil else { return }
                observation = Task {
                    do {
                        for try await value in environment.shopping.observe() {
                            withAnimation(.snappy) { items = value }
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
        withAnimation(.snappy) { try? environment.shopping.add(title: trimmed) }
        draft = ""
        // Остаёмся в поле: добавляют обычно не одно.
        addingFocused = true
    }
}
