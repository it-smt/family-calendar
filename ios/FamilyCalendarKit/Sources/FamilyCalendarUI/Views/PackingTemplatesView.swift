import FamilyCalendarKit
import OSLog
import SwiftUI

/// Managing the "what to bring" lists.
public struct PackingTemplatesView: View {
    @State private var templates: [PackingTemplate] = []
    @State private var editing: PackingTemplate?
    @State private var observation: Task<Void, Never>?

    private let environment: AppEnvironment

    public init(environment: AppEnvironment) {
        self.environment = environment
    }

    public var body: some View {
        List {
            ForEach(templates) { template in
                Button {
                    editing = template
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(template.name)
                        Text(template.items.joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
                .swipeActions {
                    Button(role: .destructive) {
                        try? environment.packingTemplates.delete(template)
                    } label: {
                        Label("Удалить", systemImage: "trash")
                    }
                }
            }
        }
        .navigationTitle("Что взять с собой")
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
                        templates = value
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
                        try? environment.packingTemplates.save(template)
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
