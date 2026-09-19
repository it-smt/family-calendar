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
        ScrollView {
            VStack(spacing: 0) {
                header
                list
            }
        }
        .headeredScreen()
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

    // MARK: Header

    private var header: some View {
        VStack(spacing: 16) {
            Theme.ScreenHeader("Покупки", subtitle: subtitle, gradient: Theme.shoppingGradient) {
                SyncIndicator(status: environment.status)
                if items.contains(where: \.isBought) {
                    Button {
                        withAnimation(.snappy) {
                            localWrite("clearing bought items") {
                                try environment.shopping.clearBought()
                            }
                        }
                    } label: {
                        Image(systemName: "checklist.checked")
                            .font(.system(size: 17, weight: .semibold))
                    }
                    .accessibilityLabel("Убрать купленное")
                }
            }

            // Поле на цветной шапке, а не под ней: это то, ради чего экран
            // открывают, и промахнуться по нему нельзя.
            addField
                .padding(.horizontal, 16)
                .offset(y: -34)
                .padding(.bottom, -34)
        }
    }

    private var addField: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Theme.shoppingGradient.from))
            TextField("Что купить", text: $draft)
                .focused($addingFocused)
                .onSubmit(add)
                .submitLabel(.done)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.systemBackground))
        )
        .shadow(color: .black.opacity(0.20), radius: 14, y: 6)
    }

    private var subtitle: String {
        let left = items.filter { !$0.isBought }.count
        return left == 0
            ? (items.isEmpty ? "Список пуст" : "Всё куплено")
            : plural(left, "пункт", "пункта", "пунктов")
    }

    // MARK: Список

    @ViewBuilder
    private var list: some View {
        LazyVStack(spacing: 8) {
            ForEach(items) { item in
                row(item)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }

            if items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "cart")
                        .font(.system(size: 34))
                        .foregroundStyle(.tertiary)
                    Text("Что нужно — сюда")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text("Второй телефон увидит, когда поймает сеть")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
                .card()
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 24)
        .padding(.bottom, 28)
    }

    private func row(_ item: ShoppingItem) -> some View {
        Button {
            withAnimation(.snappy) {
                localWrite("marking a shopping item") {
                    try environment.shopping.setBought(item, !item.isBought)
                }
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: item.isBought ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(item.isBought ? Theme.shoppingGradient.to : .secondary)
                    .symbolEffect(.bounce, value: item.isBought)
                Text(item.title)
                    .strikethrough(item.isBought)
                    .foregroundStyle(item.isBought ? .secondary : .primary)
                Spacer(minLength: 0)
                if let quantity = item.quantity, !quantity.isEmpty {
                    Text(quantity)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Theme.shoppingGradient.to.opacity(0.16), in: Capsule())
                        .foregroundStyle(Theme.shoppingGradient.from)
                }
            }
        }
        .buttonStyle(.plain)
        .card(tint: item.isBought ? nil : Theme.shoppingGradient.to)
        .opacity(item.isBought ? 0.6 : 1)
        .contextMenu {
            Button(role: .destructive) {
                localWrite("deleting a shopping item") {
                    try environment.shopping.delete(item)
                }
            } label: {
                Label("Удалить", systemImage: "trash")
            }
        }
    }

    private func add() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        withAnimation(.snappy) {
            localWrite("adding a shopping item") {
                try environment.shopping.add(title: trimmed)
            }
        }
        draft = ""
        // Остаёмся в поле: добавляют обычно не одно.
        addingFocused = true
    }
}
