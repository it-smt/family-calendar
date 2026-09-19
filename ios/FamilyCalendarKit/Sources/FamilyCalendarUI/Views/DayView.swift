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
                    timeline
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
                    Text(model.day.formatted(.dateTime.weekday(.wide)))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white.opacity(0.8))
                    Text(model.day.formatted(.dateTime.day().month(.wide)))
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }

                Spacer()

                HStack(spacing: 14) {
                    SyncIndicator(status: environment.status)
                    CategoryFilterMenu(
                        categories: Array(model.categories.values).sorted { $0.name < $1.name },
                        selection: $model.categoryFilter
                    )
                }
                .foregroundStyle(.white)
                .padding(.top, 4)
            }

            WeekStrip(selected: $model.day)

            if let next = model.nextTask {
                NextUpCard(task: next, category: next.categoryID.flatMap { model.categories[$0] })
                    .onTapGesture { editing = .editing(next) }
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
        case task(CalendarTask)

        var id: String {
            switch self {
            case .now: "now"
            case .task(let task): task.id.uuidString
            }
        }
    }

    /// The day's tasks, with the present moment slotted into its place.
    private var rows: [Row] {
        let tasks = model.visibleTasks
        guard Calendar.current.isDateInToday(model.day) else { return tasks.map(Row.task) }

        let now = Date()
        // All-day tasks sit at midnight, so they fall on the "already passed"
        // side and the marker lands below them, where the day really is.
        let passed = tasks.prefix { task in (task.startsAt ?? .distantPast) <= now }
        var rows = passed.map(Row.task)
        rows.append(.now)
        rows.append(contentsOf: tasks.dropFirst(passed.count).map(Row.task))
        return rows
    }

    @ViewBuilder
    private var timeline: some View {
        if model.visibleTasks.isEmpty {
            EmptyDay()
                .padding(.horizontal, 16)
                .padding(.top, 40)
        } else {
            LazyVStack(spacing: 0) {
                ForEach(rows) { row in
                    switch row {
                    case .now:
                        NowMarker()
                    case .task(let task):
                        TimelineRow(
                            task: task,
                            category: task.categoryID.flatMap { model.categories[$0] },
                            packing: model.packing[task.id],
                            onToggle: { withAnimation(.snappy) { model.toggleCompleted(task) } }
                        )
                        .onTapGesture { editing = .editing(task) }
                        .contextMenu {
                            Button(role: .destructive) {
                                withAnimation(.snappy) { model.delete(task) }
                            } label: {
                                Label("Удалить", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
        }
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

    /// A day either side, because that is how a person flicks through a week.
    private var daySwipe: some Gesture {
        DragGesture(minimumDistance: 30)
            .onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) * 1.5 else {
                    return
                }
                let step = value.translation.width < -60 ? 1 : (value.translation.width > 60 ? -1 : 0)
                guard step != 0 else { return }
                withAnimation(.snappy) {
                    model.day = Calendar.current.date(
                        byAdding: .day, value: step, to: model.day
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
    let task: CalendarTask
    let category: TaskCategory?

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
                if !task.isAllDay, let startsAt = task.startsAt {
                    Text(startsAt, style: .relative)
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
            } else if let startsAt = task.startsAt {
                Text(startsAt, style: .time)
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
    let task: CalendarTask
    let category: TaskCategory?
    /// Сколько из списка сборов уже отмечено, если список есть.
    let packing: SubtaskProgress?
    let onToggle: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 4) {
                Text(timeLabel)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(task.isCompleted ? .tertiary : .secondary)
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
                Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(task.isCompleted ? .green : tint)
                    .symbolEffect(.bounce, value: task.isCompleted)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 4) {
                Text(task.title)
                    .font(.body.weight(.medium))
                    .strikethrough(task.isCompleted)
                    .foregroundStyle(task.isCompleted ? .secondary : .primary)
                    .lineLimit(2)

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
        }
        .card(tint: tint)
        .opacity(task.isCompleted ? 0.65 : 1)
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
        guard let startsAt = task.startsAt else { return "—" }
        return startsAt.formatted(date: .omitted, time: .shortened)
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

struct CategoryFilterMenu: View {
    let categories: [TaskCategory]
    @Binding var selection: UUID?

    var body: some View {
        Menu {
            Button("Все") { selection = nil }
            Divider()
            ForEach(categories) { category in
                Button {
                    selection = category.id
                } label: {
                    if selection == category.id {
                        Label(category.name, systemImage: "checkmark")
                    } else {
                        Text(category.name)
                    }
                }
            }
        } label: {
            Image(
                systemName: selection == nil
                    ? "line.3.horizontal.decrease.circle"
                    : "line.3.horizontal.decrease.circle.fill"
            )
            .font(.system(size: 17, weight: .semibold))
        }
        .disabled(categories.isEmpty)
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
