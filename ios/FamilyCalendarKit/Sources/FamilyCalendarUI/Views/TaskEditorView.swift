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
                    TextField("Title", text: $model.title, axis: .vertical)
                        .font(.headline)
                    TextField("Notes", text: $model.notes, axis: .vertical)
                        .lineLimit(1...4)
                }

                Section("When") {
                    Toggle("At a time", isOn: $model.hasTime.animation())
                    if model.hasTime {
                        DatePicker("Starts", selection: $model.startsAt)
                        Picker("Lasts", selection: $model.durationMinutes) {
                            ForEach([15, 30, 45, 60, 90, 120, 180], id: \.self) { minutes in
                                Text(durationLabel(minutes)).tag(minutes)
                            }
                        }
                    } else {
                        Toggle("All day", isOn: $model.isAllDay)
                    }
                }

                Section("Where") {
                    TextField("Place", text: $model.locationName)
                    Picker("Getting there", selection: $model.travelMode) {
                        Text("Not set").tag(TravelMode.none)
                        Text("Walking").tag(TravelMode.walking)
                        Text("Driving").tag(TravelMode.driving)
                        Text("Transit").tag(TravelMode.transit)
                    }
                    .disabled(model.locationName.isEmpty)
                }

                Section("Category") {
                    Picker("Category", selection: $model.categoryID) {
                        Text("None").tag(UUID?.none)
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
                        Text("Save first, then add what to bring.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(model.isEditing ? "Task" : "New task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
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
        Section("What to bring") {
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
                        Label("Delete", systemImage: "trash")
                    }
                }
            }

            HStack {
                TextField("Add an item", text: $model.newSubtaskTitle)
                    .onSubmit { model.addSubtask() }
                Button("Add", action: model.addSubtask)
                    .disabled(model.newSubtaskTitle.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if !model.templates.isEmpty {
                Menu {
                    ForEach(model.templates) { template in
                        Button(template.name) { model.apply(template) }
                    }
                } label: {
                    Label("Use a list", systemImage: "bag")
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
