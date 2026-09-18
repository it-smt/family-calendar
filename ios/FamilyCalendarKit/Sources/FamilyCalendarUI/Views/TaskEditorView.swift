import FamilyCalendarKit
import SwiftUI

/// Creating and editing a task.
///
/// There is no "saving…" state and no failure path: the save writes to the
/// local database and the sheet closes. Whether the other phone has heard about
/// it yet is the sync engine's business, and the day list shows that separately.
public struct TaskEditorView: View {
    @State private var model: TaskEditorViewModel
    @Environment(\.dismiss) private var dismiss

    public init(environment: AppEnvironment, mode: TaskEditorViewModel.Mode, day: Date) {
        _model = State(
            wrappedValue: TaskEditorViewModel(environment: environment, mode: mode, day: day)
        )
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Название", text: $model.title, axis: .vertical)
                        .font(.headline)
                    TextField("Заметки", text: $model.notes, axis: .vertical)
                        .lineLimit(1...4)
                }

                Section("Когда") {
                    Toggle("Ко времени", isOn: $model.hasTime.animation())
                    if model.hasTime {
                        DatePicker("Начало", selection: $model.startsAt)
                        Picker("Длится", selection: $model.durationMinutes) {
                            ForEach([15, 30, 45, 60, 90, 120, 180], id: \.self) { minutes in
                                Text(durationLabel(minutes)).tag(minutes)
                            }
                        }
                    } else {
                        Toggle("Весь день", isOn: $model.isAllDay)
                    }
                }

                Section("Где") {
                    TextField("Место", text: $model.locationName)
                    Picker("Как добираться", selection: $model.travelMode) {
                        Text("Не важно").tag(TravelMode.none)
                        Text("Пешком").tag(TravelMode.walking)
                        Text("На машине").tag(TravelMode.driving)
                        Text("Транспортом").tag(TravelMode.transit)
                    }
                    .disabled(model.locationName.isEmpty)
                }

                Section("Категория") {
                    Picker("Категория", selection: $model.categoryID) {
                        Text("Без категории").tag(UUID?.none)
                        ForEach(model.categories) { category in
                            Label {
                                Text(category.name)
                            } icon: {
                                Circle().fill(Color(hex: category.colorHex)).frame(width: 10)
                            }
                            .tag(UUID?.some(category.id))
                        }
                    }
                }

                if model.isEditing {
                    subtaskSection
                } else {
                    Section {
                        Text("Сначала сохрани — потом добавишь, что взять с собой.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(model.isEditing ? "Задача" : "Новая задача")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") {
                        model.save()
                        dismiss()
                    }
                    .disabled(!model.canSave)
                }
            }
            .task { model.onAppear() }
            .onDisappear { model.onDisappear() }
        }
    }

    /// Subtasks, which double as the "what to bring" list.
    private var subtaskSection: some View {
        Section("Что взять с собой") {
            ForEach(model.subtasks) { subtask in
                Button {
                    model.toggle(subtask)
                } label: {
                    HStack {
                        Image(systemName: subtask.isDone ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(subtask.isDone ? .green : .secondary)
                        Text(subtask.title)
                            .strikethrough(subtask.isDone)
                            .foregroundStyle(subtask.isDone ? .secondary : .primary)
                    }
                }
                .buttonStyle(.plain)
                .swipeActions {
                    Button(role: .destructive) {
                        model.delete(subtask)
                    } label: {
                        Label("Удалить", systemImage: "trash")
                    }
                }
            }

            HStack {
                TextField("Добавить пункт", text: $model.newSubtaskTitle)
                    .onSubmit { model.addSubtask() }
                Button("Добавить", action: model.addSubtask)
                    .disabled(model.newSubtaskTitle.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if !model.templates.isEmpty {
                Menu {
                    ForEach(model.templates) { template in
                        Button(template.name) { model.apply(template) }
                    }
                } label: {
                    Label("Взять из шаблона", systemImage: "bag")
                        .font(.subheadline)
                }
            }
        }
    }

    private func durationLabel(_ minutes: Int) -> String {
        Duration.seconds(minutes * 60).formatted(
            .units(allowed: [.hours, .minutes], width: .abbreviated)
        )
    }
}
