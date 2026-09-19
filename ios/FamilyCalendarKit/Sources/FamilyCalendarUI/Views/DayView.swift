import FamilyCalendarKit
import OSLog
import SwiftUI

/// The day.
///
/// A coloured header carrying the date and whatever is next, then a timeline:
/// the hour down the left, a rule joining one thing to the next, and opaque
/// cards to the right of it. The rule is what makes a day read as a day rather
/// than as a list of jobs.
public struct DayView: View {
    @State private var model: DayViewModel
    @State private var editing: TaskEditorViewModel.Mode?
    private let environment: AppEnvironment

    public init(environment: AppEnvironment) {
        self.environment = environment
        _model = State(wrappedValue: DayViewModel(environment: environment))
    }

    public var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(spacing: 0) {
                    header
                    notices
                    switch model.scale {
                    case .day: timeline
                    case .week: weekList
                    case .month: monthGrid
                    }
                }
            }
            .contentBackground()
            .ignoresSafeArea(edges: .top)
            .gesture(daySwipe)
            .refreshable { environment.syncNow() }

            addButton
        }
        .sheet(item: $editing) { mode in
            TaskEditorView(environment: environment, mode: mode, day: model.day)
        }
        .task { model.onAppear() }
        .onDisappear { model.onDisappear() }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(subtitleText)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white.opacity(0.8))
                    Text(titleText)
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }

                Spacer()

                HStack(spacing: 14) {
                    SyncIndicator(status: environment.status)
                    FilterMenu(
                        categories: Array(model.categories.values).sorted { $0.name < $1.name },
                        people: Array(model.people.values).sorted { $0.displayName < $1.displayName },
                        category: $model.categoryFilter,
                        assignee: $model.assigneeFilter
                    )
                }
                .foregroundStyle(.white)
                .padding(.top, 4)
            }

            Picker("", selection: $model.scale.animation(.snappy)) {
                ForEach(CalendarScale.allCases) { scale in
                    Text(scale.label).tag(scale)
                }
            }
            .pickerStyle(.segmented)

            if model.scale != .month {
                WeekStrip(selected: $model.day)
            }

            if model.scale == .day, let next = model.nextItem {
                NextUpCard(
                    item: next,
                    category: next.task.categoryID.flatMap { model.categories[$0] }
                )
                .onTapGesture { editing = .editing(next.task) }
                .transition(.scale(scale: 0.96).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 62)
        .padding(.bottom, 20)
        .background(Theme.HeaderBackground(at: model.day))
        .clipShape(
            UnevenRoundedRectangle(
                bottomLeadingRadius: 30, bottomTrailingRadius: 30, style: .continuous
            )
        )
    }

    // MARK: Замены

    /// Правки, которые проиграли чужим. Над списком, а не в настройках: их
    /// показывают один раз, и если промотать мимо — их больше негде увидеть.
    @ViewBuilder
    private var notices: some View {
        if !model.notices.isEmpty {
            VStack(spacing: 8) {
                ForEach(model.notices) { notice in
                    SupersededEditRow(
                        notice: notice,
                        onRestore: { withAnimation(.snappy) { model.restore(notice) } },
                        onDismiss: { withAnimation(.snappy) { model.dismiss(notice) } }
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
        }
    }

    // MARK: Timeline

    private enum Row: Identifiable {
        case now
        case item(DayItem)

        var id: String {
            switch self {
            case .now: "now"
            case .item(let item): item.id
            }
        }
    }

    /// The day's lines, with the present moment slotted into its place.
    private var rows: [Row] {
        let items = model.visibleItems
        guard Calendar.current.isDateInToday(model.day) else { return items.map(Row.item) }

        let now = Date()
        // All-day tasks sit at midnight, so they fall on the "already passed"
        // side and the marker lands below them, where the day really is.
        let passed = items.prefix { $0.occurrence <= now }
        var rows = passed.map(Row.item)
        rows.append(.now)
        rows.append(contentsOf: items.dropFirst(passed.count).map(Row.item))
        return rows
    }

    @ViewBuilder
    private var timeline: some View {
        if model.visibleItems.isEmpty {
            EmptyDay()
                .padding(.horizontal, 16)
                .padding(.top, 40)
        } else {
            LazyVStack(spacing: 0) {
                ForEach(rows) { row in
                    switch row {
                    case .now:
                        NowMarker()
                    case .item(let item):
                        TimelineRow(
                            item: item,
                            category: item.task.categoryID.flatMap { model.categories[$0] },
                            packing: model.packing[item.task.id],
                            assignee: item.task.assigneeID.flatMap { model.people[$0] },
                            hasAlert: model.alerts.contains(item.task.id),
                            onToggle: { withAnimation(.snappy) { model.toggleCompleted(item) } }
                        )
                        .onTapGesture { editing = .editing(item.task) }
                        .contextMenu {
                            // У повтора две разные «удалить», и спутать их
                            // дорого: одна убирает вторник, другая — все
                            // вторники до конца времён.
                            if item.isRepeating {
                                Button {
                                    withAnimation(.snappy) { model.skip(item) }
                                } label: {
                                    Label("Пропустить этот раз", systemImage: "calendar.badge.minus")
                                }
                                Button(role: .destructive) {
                                    withAnimation(.snappy) { model.delete(item) }
                                } label: {
                                    Label("Удалить все повторы", systemImage: "trash")
                                }
                            } else {
                                Button(role: .destructive) {
                                    withAnimation(.snappy) { model.delete(item) }
                                } label: {
                                    Label("Удалить", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
        }
    }

    // MARK: Заголовок

    private var titleText: String {
        switch model.scale {
        case .day:
            model.day.formatted(.dateTime.day().month(.wide))
        case .week:
            weekTitle
        case .month:
            model.day.formatted(.dateTime.month(.wide).year())
        }
    }

    private var subtitleText: String {
        switch model.scale {
        case .day: model.day.formatted(.dateTime.weekday(.wide))
        case .week: "Неделя"
        case .month: plural(model.items.count, "дело", "дела", "дел")
        }
    }

    private var weekTitle: String {
        let calendar = Calendar.current
        let range = model.range
        let last = calendar.date(byAdding: .day, value: -1, to: range.upperBound)
            ?? range.upperBound
        let sameMonth = calendar.isDate(range.lowerBound, equalTo: last, toGranularity: .month)
        let from = sameMonth
            ? range.lowerBound.formatted(.dateTime.day())
            : range.lowerBound.formatted(.dateTime.day().month(.abbreviated))
        return "\(from) – \(last.formatted(.dateTime.day().month(.abbreviated)))"
    }

    // MARK: Неделя

    /// Семь дней подряд. Сетка на телефоне помещает по три слова в клетку, а
    /// список — целое дело, и именно его и надо прочитать.
    private var weekList: some View {
        let calendar = Calendar.current
        let byDay = model.itemsByDay
        let days = stride(from: 0, to: 7, by: 1).compactMap {
            calendar.date(byAdding: .day, value: $0, to: model.range.lowerBound)
        }

        return LazyVStack(alignment: .leading, spacing: 18) {
            ForEach(days, id: \.self) { day in
                let lines = byDay[calendar.startOfDay(for: day)] ?? []
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        SectionLabel(day.formatted(.dateTime.weekday(.wide).day().month()))
                        if calendar.isDateInToday(day) {
                            Text("сегодня")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.red)
                        }
                    }

                    if lines.isEmpty {
                        Text("Свободно")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 4)
                    } else {
                        ForEach(lines) { item in
                            compactRow(item)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 20)
        .padding(.bottom, 28)
    }

    private func compactRow(_ item: DayItem) -> some View {
        let category = item.task.categoryID.flatMap { model.categories[$0] }
        let tint = category.map { Color(hex: $0.colorHex) } ?? Theme.unlabelled
        return HStack(spacing: 10) {
            Text(item.task.isAllDay ? "весь день" : item.occurrence.formatted(date: .omitted, time: .shortened))
                .font(.caption.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .leading)

            Text(item.task.title)
                .font(.subheadline)
                .strikethrough(item.isCompleted)
                .foregroundStyle(item.isCompleted ? .secondary : .primary)
                .lineLimit(1)

            Spacer(minLength: 0)

            if item.isRepeating {
                Image(systemName: "repeat").font(.system(size: 9)).foregroundStyle(.tertiary)
            }
            if let assignee = item.task.assigneeID.flatMap({ model.people[$0] }) {
                Circle()
                    .fill(Color(hex: assignee.color))
                    .frame(width: 8, height: 8)
                    .accessibilityLabel(assignee.displayName)
            }
        }
        .card(tint: tint)
        .opacity(item.isCompleted ? 0.6 : 1)
        .onTapGesture { editing = .editing(item.task) }
    }

    // MARK: Месяц

    /// Сетка и под ней выбранный день. Точки в клетке — цвета категорий: по
    /// ним видно, какой день чем занят, не открывая его.
    private var monthGrid: some View {
        let calendar = Calendar.current
        let byDay = model.itemsByDay
        let days = stride(from: 0, to: monthDayCount, by: 1).compactMap {
            calendar.date(byAdding: .day, value: $0, to: model.range.lowerBound)
        }
        let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)

        return VStack(alignment: .leading, spacing: 16) {
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(weekdayNames, id: \.self) { name in
                    Text(name)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                }

                ForEach(days, id: \.self) { day in
                    monthCell(day, lines: byDay[calendar.startOfDay(for: day)] ?? [])
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(model.day.formatted(.dateTime.weekday(.wide).day().month()))
                if model.visibleItems.isEmpty {
                    Text("Свободно")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 4)
                } else {
                    ForEach(model.visibleItems) { item in
                        compactRow(item)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 20)
        .padding(.bottom, 28)
    }

    private var monthDayCount: Int {
        let calendar = Calendar.current
        let range = model.range
        let days = calendar.dateComponents(
            [.day], from: range.lowerBound, to: range.upperBound
        ).day ?? 35
        return max(days, 0)
    }

    private var weekdayNames: [String] {
        let calendar = Calendar.current
        let symbols = calendar.veryShortWeekdaySymbols
        // Неделя начинается там, где её начинает система: в России с
        // понедельника, не везде.
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    private func monthCell(_ day: Date, lines: [DayItem]) -> some View {
        let calendar = Calendar.current
        let isSelected = calendar.isDate(day, inSameDayAs: model.day)
        let isToday = calendar.isDateInToday(day)
        let inMonth = calendar.isDate(day, equalTo: model.day, toGranularity: .month)
        let colours = lines.prefix(3).map { item in
            item.task.categoryID
                .flatMap { model.categories[$0] }
                .map { Color(hex: $0.colorHex) } ?? Theme.unlabelled
        }

        return Button {
            withAnimation(.snappy) { model.day = day }
        } label: {
            VStack(spacing: 3) {
                Text(day.formatted(.dateTime.day()))
                    .font(.system(size: 14, weight: isToday ? .bold : .regular, design: .rounded))
                    .monospacedDigit()
                    // Цвет и приглушённость раздельно: `Color` знает `.primary`
                    // и `.secondary`, но не `.tertiary` — это иерархический
                    // стиль, и в одной тернарной операции с `Color.white` он не
                    // сходится по типу.
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                    .opacity(inMonth ? 1 : 0.35)

                HStack(spacing: 2) {
                    ForEach(Array(colours.enumerated()), id: \.offset) { _, colour in
                        Circle().fill(isSelected ? Color.white : colour).frame(width: 4, height: 4)
                    }
                }
                .frame(height: 4)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Theme.Hour.at(Date()).gradient.from)
                } else if isToday {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(Color.red.opacity(0.5), lineWidth: 1)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: Chrome

    private var addButton: some View {
        Button {
            editing = .creating
        } label: {
            Image(systemName: "plus")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 58, height: 58)
                .background { Theme.HeaderBackground(at: model.day).clipShape(Circle()) }
                .shadow(color: .black.opacity(0.25), radius: 12, y: 5)
        }
        .padding(.bottom, 12)
    }

    /// Листание вбок — на столько, сколько сейчас показано: день, неделя,
    /// месяц. Свайп по месяцу на один день был бы свайпом в никуда.
    private var daySwipe: some Gesture {
        DragGesture(minimumDistance: 30)
            .onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) * 1.5 else {
                    return
                }
                let step = value.translation.width < -60 ? 1 : (value.translation.width > 60 ? -1 : 0)
                guard step != 0 else { return }

                let unit: Calendar.Component = switch model.scale {
                case .day: .day
                case .week: .weekOfYear
                case .month: .month
                }

                withAnimation(.snappy) {
                    model.day = Calendar.current.date(
                        byAdding: unit, value: step, to: model.day
                    ) ?? model.day
                }
            }
    }
}

// MARK: - Pieces

/// The week, in the header, so moving a few days is one tap.
struct WeekStrip: View {
    @Binding var selected: Date
    private let calendar = Calendar.current

    var body: some View {
        HStack(spacing: 4) {
            ForEach(days, id: \.self) { day in
                let isSelected = calendar.isDate(day, inSameDayAs: selected)
                let isToday = calendar.isDateInToday(day)

                Button {
                    withAnimation(.snappy) { selected = day }
                } label: {
                    VStack(spacing: 2) {
                        Text(day.formatted(.dateTime.weekday(.abbreviated)))
                            .font(.system(size: 11, weight: .medium))
                        Text(day.formatted(.dateTime.day()))
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                    }
                    .foregroundStyle(isSelected ? Color(hex: "#20243A") : .white.opacity(0.9))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background {
                        if isSelected {
                            Capsule().fill(.white)
                        } else if isToday {
                            Capsule().stroke(.white.opacity(0.55), lineWidth: 1.2)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var days: [Date] {
        guard let week = calendar.dateInterval(of: .weekOfYear, for: selected) else { return [] }
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: week.start) }
    }
}

/// The next thing due, on the header, where the eye lands first.
struct NextUpCard: View {
    let item: DayItem
    let category: TaskCategory?

    private var task: CalendarTask { item.task }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(category.map { Color(hex: $0.colorHex) } ?? Theme.unlabelled)
                .frame(width: 5, height: 40)

            VStack(alignment: .leading, spacing: 3) {
                // "Дальше" is a claim about the clock, and an all-day task
                // makes no claim about the clock.
                Text(task.isAllDay ? "Сегодня" : "Дальше")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Text(task.title)
                    .font(.headline)
                    .lineLimit(1)
                if !task.isAllDay {
                    Text(item.occurrence, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 4)

            if task.isAllDay {
                Text("весь\nдень")
                    .font(.system(size: 13, weight: .semibold))
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(.secondary)
            } else {
                Text(item.occurrence, style: .time)
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.systemBackground))
        )
        .shadow(color: .black.opacity(0.22), radius: 14, y: 6)
    }
}

/// One line of the timeline: the hour, the rule, the card.
struct TimelineRow: View {
    let item: DayItem
    let category: TaskCategory?
    /// Сколько из списка сборов уже отмечено, если список есть.
    let packing: SubtaskProgress?
    /// На ком задача, если на ком-то.
    let assignee: User?
    /// Зазвонит ли она.
    let hasAlert: Bool
    let onToggle: () -> Void

    private var task: CalendarTask { item.task }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 4) {
                Text(timeLabel)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(item.isCompleted ? .tertiary : .secondary)
                Rectangle()
                    .fill(Color(.separator))
                    .frame(width: 1)
                    .frame(maxHeight: .infinity)
            }
            .frame(width: 46)

            card.padding(.bottom, 12)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var card: some View {
        HStack(spacing: 12) {
            Button(action: onToggle) {
                Image(systemName: item.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(item.isCompleted ? .green : tint)
                    .symbolEffect(.bounce, value: item.isCompleted)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(task.title)
                        .font(.body.weight(.medium))
                        .strikethrough(item.isCompleted)
                        .foregroundStyle(item.isCompleted ? .secondary : .primary)
                        .lineLimit(2)

                    if hasAlert {
                        Image(systemName: "bell.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .accessibilityLabel("с напоминанием")
                    }

                    if item.isRepeating {
                        Image(systemName: "repeat")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .accessibilityLabel("повторяется")
                    }
                }

                if !details.isEmpty || packing != nil {
                    HStack(spacing: 6) {
                        ForEach(details, id: \.self) { detail in
                            Text(detail)
                                .font(.caption)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(tint.opacity(0.16), in: Capsule())
                                .foregroundStyle(tint)
                        }

                        // Собрано ли. Иначе про список приходится помнить —
                        // а он ровно для того, чтобы не приходилось.
                        if let packing, packing.total > 0 {
                            let colour = packing.isComplete ? Color.green : tint
                            HStack(spacing: 3) {
                                Image(systemName: packing.isComplete ? "bag.fill" : "bag")
                                Text("\(packing.done)/\(packing.total)").monospacedDigit()
                            }
                            .font(.caption)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(colour.opacity(0.16), in: Capsule())
                            .foregroundStyle(colour)
                            .accessibilityLabel(
                                "собрано \(packing.done) из \(packing.total)"
                            )
                        }
                    }
                }
            }

            Spacer(minLength: 0)

            // Инициал того, на ком задача. Для двоих одной буквы достаточно,
            // а цвет свой у каждого.
            if let assignee {
                Text(String(assignee.displayName.prefix(1)).uppercased())
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color(hex: assignee.color)))
                    .accessibilityLabel(assignee.displayName)
            }
        }
        .card(tint: tint)
        .opacity(item.isCompleted ? 0.65 : 1)
    }

    private var tint: Color {
        category.map { Color(hex: $0.colorHex) } ?? Theme.unlabelled
    }

    private var details: [String] {
        var parts: [String] = []
        if let category { parts.append(category.name) }
        if let place = task.locationName, !place.isEmpty { parts.append(place) }
        return parts
    }

    private var timeLabel: String {
        // An all-day task is stored at midnight, which is a time nobody meant.
        if task.isAllDay { return "весь\nдень" }
        // The instant this line falls on, not the row's: a repeat is one row
        // and many Tuesdays.
        return item.occurrence.formatted(date: .omitted, time: .shortened)
    }
}

/// Where the day has got to.
struct NowMarker: View {
    var body: some View {
        HStack(spacing: 12) {
            Text(Date(), style: .time)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.red)
                .frame(width: 46)

            Circle().fill(.red).frame(width: 7, height: 7)
            Rectangle().fill(.red.opacity(0.55)).frame(height: 1.5)
        }
        .padding(.bottom, 12)
    }
}

struct EmptyDay: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.seal")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text("Ничего не запланировано")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
        .card()
    }
}

/// The only thing the interface says about the network.
struct SyncIndicator: View {
    let status: SyncStatus

    var body: some View {
        if status.hasUnsyncedChanges {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 15, weight: .semibold))
                .accessibilityLabel(
                    plural(status.pendingChanges, "изменение", "изменения", "изменений")
                        + " не отправлено"
                )
        }
    }
}

/// По категории и по тому, на ком задача.
struct FilterMenu: View {
    let categories: [TaskCategory]
    let people: [User]
    @Binding var category: UUID?
    @Binding var assignee: UUID?

    private var isFiltering: Bool { category != nil || assignee != nil }

    var body: some View {
        Menu {
            if isFiltering {
                Button("Показать всё") {
                    category = nil
                    assignee = nil
                }
                Divider()
            }

            if !categories.isEmpty {
                Section("Категория") {
                    ForEach(categories) { item in
                        Button {
                            category = category == item.id ? nil : item.id
                        } label: {
                            if category == item.id {
                                Label(item.name, systemImage: "checkmark")
                            } else {
                                Text(item.name)
                            }
                        }
                    }
                }
            }

            if people.count > 1 {
                Section("Кто делает") {
                    ForEach(people) { person in
                        Button {
                            assignee = assignee == person.id ? nil : person.id
                        } label: {
                            if assignee == person.id {
                                Label(person.displayName, systemImage: "checkmark")
                            } else {
                                Text(person.displayName)
                            }
                        }
                    }
                }
            }
        } label: {
            Image(
                systemName: isFiltering
                    ? "line.3.horizontal.decrease.circle.fill"
                    : "line.3.horizontal.decrease.circle"
            )
            .font(.system(size: 17, weight: .semibold))
        }
        .disabled(categories.isEmpty && people.count < 2)
    }
}

extension TaskEditorViewModel.Mode: Identifiable {
    public var id: String {
        switch self {
        case .creating: "new"
        case .editing(let task): task.id.uuidString
        }
    }
}
