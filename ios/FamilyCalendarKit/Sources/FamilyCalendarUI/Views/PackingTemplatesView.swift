import FamilyCalendarKit
import OSLog
import SwiftUI

/// Списки «что взять с собой».
///
/// Их собирают один раз и подставляют в задачу — на бассейн, на дачу, к врачу.
public struct PackingTemplatesView: View {
    @State private var templates: [PackingTemplate] = []
    @State private var editing: PackingTemplate?
    @State private var observation: Task<Void, Never>?

    private let environment: AppEnvironment

    public init(environment: AppEnvironment) {
        self.environment = environment
    }

    public var body: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(templates) { template in
                    card(template, tint: Theme.swatchColor(for: template.id))
                        .transition(.opacity.combined(with: .scale(scale: 0.97)))
                }

                if templates.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "bag")
                            .font(.system(size: 34))
                            .foregroundStyle(.tertiary)
                        Text("Списков пока нет")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                        Text("Собери один раз — потом подставится в задачу")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 44)
                    .card()
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 18)
        }
        .contentBackground()
        .navigationTitle("Что взять с собой")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button {
                editing = PackingTemplate(householdID: environment.householdID, name: "")
            } label: {
                Image(systemName: "plus")
            }
        }
        .sheet(item: $editing) { template in
            PackingTemplateEditor(environment: environment, template: template)
        }
        .task {
            guard observation == nil else { return }
            observation = Task {
                do {
                    for try await value in environment.packingTemplates.observe() {
                        withAnimation(.snappy) { templates = value }
                    }
                } catch {
                    Log.database.error("template observation ended: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        .onDisappear {
            observation?.cancel()
            observation = nil
        }
    }

    private func card(_ template: PackingTemplate, tint: Color) -> some View {
        Button {
            editing = template
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: "bag.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(tint))
                    Text(template.name)
                        .font(.body.weight(.medium))
                    Spacer(minLength: 0)
                    Text("\(template.items.count)")
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                if !template.items.isEmpty {
                    // Первые несколько пунктов прямо на карточке: обычно этого
                    // хватает, чтобы узнать список и не открывать его.
                    HStack(spacing: 6) {
                        ForEach(template.items.prefix(3), id: \.self) { item in
                            Text(item)
                                .font(.caption)
                                .lineLimit(1)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(tint.opacity(0.16), in: Capsule())
                                .foregroundStyle(tint)
                        }
                        if template.items.count > 3 {
                            Text("+\(template.items.count - 3)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .card(tint: tint)
        .contextMenu {
            Button(role: .destructive) {
                withAnimation(.snappy) {
                    localWrite("deleting a packing list") {
                        try environment.packingTemplates.delete(template)
                    }
                }
            } label: {
                Label("Удалить", systemImage: "trash")
            }
        }
    }
}

struct PackingTemplateEditor: View {
    let environment: AppEnvironment
    @State private var template: PackingTemplate
    @State private var newItem: String = ""
    @Environment(\.dismiss) private var dismiss

    init(environment: AppEnvironment, template: PackingTemplate) {
        self.environment = environment
        _template = State(wrappedValue: template)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Название", text: $template.name)

                Section("Пункты") {
                    ForEach(Array(template.items.enumerated()), id: \.offset) { index, item in
                        Text(item)
                            .swipeActions {
                                Button(role: .destructive) {
                                    template.items.remove(at: index)
                                } label: {
                                    Label("Удалить", systemImage: "trash")
                                }
                            }
                    }
                    HStack {
                        TextField("Добавить пункт", text: $newItem)
                            .onSubmit(addItem)
                        Button("Добавить", action: addItem)
                            .disabled(newItem.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .navigationTitle(template.name.isEmpty ? "Новый список" : template.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") {
                        localWrite("saving a packing list") {
                            try environment.packingTemplates.save(template)
                        }
                        dismiss()
                    }
                    .disabled(template.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func addItem() {
        let trimmed = newItem.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        template.items.append(trimmed)
        newItem = ""
    }
}
