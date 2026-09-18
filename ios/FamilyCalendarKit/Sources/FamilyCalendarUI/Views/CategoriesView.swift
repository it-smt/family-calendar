import FamilyCalendarKit
import OSLog
import SwiftUI

/// Категории. Название и цвет — больше ничего.
///
/// Цвет здесь не украшение: он один и тот же на полоске карточки в дне, на
/// кружке в редакторе и в фильтре, так что это единственное, по чему в списке
/// из восьми дел видно, какие из них твои.
public struct CategoriesView: View {
    @State private var categories: [TaskCategory] = []
    @State private var newName: String = ""
    @State private var newColorHex: String = Theme.swatches[0]
    @State private var observation: Task<Void, Never>?
    @FocusState private var naming: Bool

    private let environment: AppEnvironment

    public init(environment: AppEnvironment) {
        self.environment = environment
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(spacing: 8) {
                    SectionLabel("Новая")
                    editor
                }

                if !categories.isEmpty {
                    VStack(spacing: 8) {
                        SectionLabel(plural(categories.count, "категория", "категории", "категорий"))
                        ForEach(categories) { category in
                            row(category)
                                .transition(.opacity.combined(with: .scale(scale: 0.97)))
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 18)
        }
        .contentBackground()
        .navigationTitle("Категории")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard observation == nil else { return }
            observation = Task {
                do {
                    for try await value in environment.categories.observeAll() {
                        withAnimation(.snappy) { categories = value }
                    }
                } catch {
                    Log.database.error("category observation ended: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        .onDisappear {
            observation?.cancel()
            observation = nil
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Circle()
                    .fill(Color(hex: newColorHex))
                    .frame(width: 26, height: 26)
                TextField("Название", text: $newName)
                    .focused($naming)
                    .onSubmit(add)
                    .submitLabel(.done)
            }

            // Восемь готовых цветов вместо ColorPicker. Свободный выбор рано
            // или поздно даёт два почти одинаковых бежевых, и тогда полоска на
            // карточке перестаёт что-либо значить.
            HStack(spacing: 10) {
                ForEach(Theme.swatches, id: \.self) { hex in
                    Button {
                        withAnimation(.snappy) { newColorHex = hex }
                    } label: {
                        Circle()
                            .fill(Color(hex: hex))
                            .frame(width: 28, height: 28)
                            .overlay {
                                if hex == newColorHex {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundStyle(.white)
                                }
                            }
                            .overlay {
                                Circle()
                                    .stroke(Color(hex: hex).opacity(0.35), lineWidth: 4)
                                    .scaleEffect(hex == newColorHex ? 1.28 : 1)
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(hex)
                }
            }
            .frame(maxWidth: .infinity)

            Button(action: add) {
                Text("Добавить")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(Color(hex: newColorHex))
                    )
            }
            .buttonStyle(.plain)
            .disabled(trimmedName.isEmpty)
            .opacity(trimmedName.isEmpty ? 0.4 : 1)
        }
        .card(tint: Color(hex: newColorHex))
    }

    private func row(_ category: TaskCategory) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color(hex: category.colorHex))
                .frame(width: 20, height: 20)
            Text(category.name)
            Spacer(minLength: 0)
            Button(role: .destructive) {
                withAnimation(.snappy) { try? environment.categories.delete(category) }
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .card(tint: Color(hex: category.colorHex))
    }

    private var trimmedName: String {
        newName.trimmingCharacters(in: .whitespaces)
    }

    private func add() {
        guard !trimmedName.isEmpty else { return }
        withAnimation(.snappy) {
            try? environment.categories.create(
                name: trimmedName, colorHex: newColorHex, icon: nil
            )
        }
        newName = ""
        // Следующий цвет — следующий в палитре, чтобы две подряд заведённые
        // категории не оказались одного цвета просто потому, что его не
        // переключили.
        if let index = Theme.swatches.firstIndex(of: newColorHex) {
            newColorHex = Theme.swatches[(index + 1) % Theme.swatches.count]
        }
        naming = true
    }
}
