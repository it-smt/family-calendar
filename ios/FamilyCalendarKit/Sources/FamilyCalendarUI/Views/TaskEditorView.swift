import FamilyCalendarKit
import MapKit
import SwiftUI

/// Creating and editing a task.
///
/// There is no "saving…" state and no failure path: the save writes to the
/// local database and the sheet closes. Whether the other phone has heard about
/// it yet is the sync engine's business, and the day list shows that separately.
public struct TaskEditorView: View {
    @State private var model: TaskEditorViewModel
    @State private var picking = false
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

                    Button {
                        picking = true
                    } label: {
                        Label(
                            model.isPinned ? "Место на карте выбрано" : "Найти на карте",
                            systemImage: model.isPinned ? "mappin.circle.fill" : "mappin.and.ellipse"
                        )
                        .font(.subheadline)
                        .foregroundStyle(model.isPinned ? Color.green : Color.accentColor)
                    }

                    if model.isPinned {
                        Button {
                            openInMaps()
                        } label: {
                            Label("Маршрут", systemImage: "arrow.triangle.turn.up.right.circle")
                                .font(.subheadline)
                        }
                    }

                    Picker("Как добираться", selection: $model.travelMode) {
                        Text("Не важно").tag(TravelMode.none)
                        Text("Пешком").tag(TravelMode.walking)
                        Text("На машине").tag(TravelMode.driving)
                        Text("Транспортом").tag(TravelMode.transit)
                    }
                    .disabled(model.locationName.isEmpty)

                    if !model.locationName.isEmpty && !model.isPinned {
                        Text("""
                            Без точки на карте «когда выходить» посчитать не из \
                            чего. Название словами работает и так.
                            """)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Повтор") {
                    Picker("Повторять", selection: $model.repeatRule) {
                        if model.repeatRule == .custom {
                            Text(RepeatRule.custom.label).tag(RepeatRule.custom)
                        }
                        ForEach(RepeatRule.offered) { rule in
                            Text(rule.label).tag(rule)
                        }
                    }
                    if model.repeatRule != .never {
                        Text("Отсчёт от даты выше. Отдельный день можно пропустить долгим нажатием по нему в списке.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Напомнить") {
                    reminderRows
                }

                Section("Категория") {
                    categoryChips
                }

                if model.people.count > 1 {
                    Section("Кто делает") {
                        assigneeChips
                    }
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
            .sheet(isPresented: $picking) {
                PlacePicker(query: model.locationName) { place in
                    model.pin(
                        PinnedPlace(
                            name: place.name,
                            latitude: place.latitude,
                            longitude: place.longitude
                        )
                    )
                }
            }
            .task { model.onAppear() }
            .onDisappear { model.onDisappear() }
        }
    }

    /// Напоминания. Сколько угодно на задачу — «за день» и «за 15 минут»
    /// это разные вещи, и человеку обычно нужны обе.
    @ViewBuilder
    private var reminderRows: some View {
        ForEach(model.reminders) { reminder in
            HStack {
                Image(systemName: reminder.kind == .leaveTime ? "figure.walk" : "bell.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.swatchColor(1))
                Text(Self.reminderLabel(reminder))
                Spacer(minLength: 0)
                Button {
                    withAnimation(.snappy) { model.delete(reminder) }
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }

        Menu {
            ForEach(Self.offsets, id: \.minutes) { offset in
                Button(offset.label) { withAnimation(.snappy) { model.addReminder(offsetMinutes: offset.minutes) } }
            }
            if model.canRemindToLeave {
                Divider()
                Button("Когда выходить") {
                    withAnimation(.snappy) {
                        model.addReminder(offsetMinutes: 0, kind: .leaveTime)
                    }
                }
            }
        } label: {
            Label(
                model.reminders.isEmpty ? "Добавить напоминание" : "Ещё одно",
                systemImage: "bell.badge"
            )
            .font(.subheadline)
        }

        if model.isAllDay && !model.reminders.isEmpty {
            Text("У задачи на весь день время отсчитывается от полуночи.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Смещения отрицательные: «за 15 минут» это минус пятнадцать от начала.
    private static let offsets: [(minutes: Int, label: String)] = [
        (0, "В момент начала"),
        (-5, "За 5 минут"),
        (-15, "За 15 минут"),
        (-30, "За 30 минут"),
        (-60, "За час"),
        (-180, "За 3 часа"),
        (-1440, "За день"),
    ]

    private static func reminderLabel(_ reminder: Reminder) -> String {
        if reminder.kind == .leaveTime { return "Когда выходить" }
        return offsets.first { $0.minutes == reminder.offsetMinutes }?.label
            ?? "За \(-reminder.offsetMinutes) мин"
    }

    /// Кто делает. Показывается только когда в доме есть второй человек —
    /// до этого выбор из одного варианта.
    private var assigneeChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(
                    title: "Не важно",
                    colour: Theme.unlabelled,
                    isSelected: model.assigneeID == nil
                ) {
                    model.assigneeID = nil
                }

                ForEach(model.people) { person in
                    chip(
                        title: person.displayName,
                        colour: Color(hex: person.color),
                        isSelected: model.assigneeID == person.id
                    ) {
                        model.assigneeID = person.id
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .scrollClipDisabled()
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
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
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

    /// Отдаёт точку системным картам. Строить маршрут самим незачем — это
    /// делает приложение, которое для этого и стоит на телефоне.
    private func openInMaps() {
        guard let pinned = model.pinned else { return }
        let placemark = MKPlacemark(
            coordinate: CLLocationCoordinate2D(
                latitude: pinned.latitude, longitude: pinned.longitude
            )
        )
        let destination = MKMapItem(placemark: placemark)
        destination.name = pinned.name
        destination.openInMaps(
            launchOptions: [MKLaunchOptionsDirectionsModeKey: model.travelMode.mapsMode]
        )
    }

    private func durationLabel(_ minutes: Int) -> String {
        Duration.seconds(minutes * 60).formatted(
            .units(allowed: [.hours, .minutes], width: .abbreviated)
        )
    }
}
