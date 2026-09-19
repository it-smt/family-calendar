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
                    // Дата есть всегда. Раньше её можно было не ставить — и
                    // задача сохранялась в базу, которую ни один экран не
                    // показывает: день ищет задачи по дате, а её не было.
                    Toggle("Весь день", isOn: $model.isAllDay.animation())
                    DatePicker(
                        "Когда",
                        selection: $model.startsAt,
                        displayedComponents: model.isAllDay ? [.date] : [.date, .hourAndMinute]
                    )
                    if !model.isAllDay {
                        Picker("Длится", selection: $model.durationMinutes) {
                            ForEach([15, 30, 45, 60, 90, 120, 180], id: \.self) { minutes in
                                Text(durationLabel(minutes)).tag(minutes)
                            }
                        }
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
                    categoryChips
                }

                subtaskSection
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

    /// Категории — плашками, а не выпадающим списком.
    ///
    /// Цвет категории виден на каждой карточке в дне, и выбирают его именно по
    /// цвету; в `Picker` он свёрнут в одну строку и до раскрытия его не видно.
    private var categoryChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(
                    title: "Без категории",
                    colour: Theme.unlabelled,
                    isSelected: model.categoryID == nil
                ) {
                    model.categoryID = nil
                }

                ForEach(model.categories) { category in
                    chip(
                        title: category.name,
                        colour: Color(hex: category.colorHex),
                        isSelected: model.categoryID == category.id
                    ) {
                        model.categoryID = category.id
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .scrollClipDisabled()
    }

    private func chip(
        title: String, colour: Color, isSelected: Bool, select: @escaping () -> Void
    ) -> some View {
        Button {
            withAnimation(.snappy) { select() }
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(isSelected ? Color.white : colour)
                    .frame(width: 9, height: 9)
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(isSelected ? Color.white : .primary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                Capsule().fill(isSelected ? colour : Color(.tertiarySystemFill))
            )
        }
        .buttonStyle(.plain)
    }

    /// Subtasks, which double as the "what to bring" list.
    ///
    /// Шаблон подставляется и в ещё не сохранённую задачу: пункты лежат в
    /// редакторе и записываются вместе с ней.
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
