import FamilyCalendarKit
import OSLog
import SwiftUI

/// The day. The screen the app opens on.
///
/// Swipe sideways to move a day, or tap one in the strip. The list itself is
/// cards over the gradient rather than a table: a day has three or four things
/// in it, and a full-width separator between each of them makes four things
/// look like a form to fill in.
public struct DayView: View {
    @State private var model: DayViewModel
    @State private var editing: TaskEditorViewModel.Mode?
    @State private var dragOffset: CGFloat = 0
    private let environment: AppEnvironment

    public init(environment: AppEnvironment) {
        self.environment = environment
        _model = State(wrappedValue: DayViewModel(environment: environment))
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    WeekStrip(selected: $model.day)
                        .padding(.bottom, 2)

                    ForEach(model.notices) { notice in
                        SupersededEditRow(
                            notice: notice,
                            onRestore: { model.restore(notice) },
                            onDismiss: { model.dismiss(notice) }
                        )
                        .card(emphasised: true)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    dayContent
                        .id(model.day)
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .leading).combined(with: .opacity)
                        ))
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 90)
            }
            .themedScreen(at: model.day)
            .offset(x: dragOffset / 3)
            .gesture(daySwipe)
            .safeAreaInset(edge: .bottom) { addButton }
            .navigationTitle("")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { title }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    SyncIndicator(status: environment.status)
                    CategoryFilterMenu(
                        categories: Array(model.categories.values).sorted { $0.name < $1.name },
                        selection: $model.categoryFilter
                    )
                }
            }
            .sheet(item: $editing) { mode in
                TaskEditorView(environment: environment, mode: mode, day: model.day)
            }
            .refreshable { environment.syncNow() }
            .task { model.onAppear() }
            .onDisappear { model.onDisappear() }
        }
    }

    // MARK: Pieces

    private var title: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(model.day.formatted(.dateTime.day().month(.wide)))
                .font(.title3.weight(.semibold))
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var subtitle: String {
        if Calendar.current.isDateInToday(model.day) {
            return model.unfinishedCount == 0
                ? "сегодня — всё сделано"
                : "сегодня · " + plural(model.unfinishedCount, "дело", "дела", "дел")
        }
        return model.day.formatted(.dateTime.weekday(.wide))
    }

    @ViewBuilder
    private var dayContent: some View {
        if model.visibleTasks.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "sun.horizon")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("Ничего не запланировано")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
            .card()
        } else {
            let next = model.nextTask
            ForEach(model.visibleTasks) { task in
                TaskCard(
                    task: task,
                    category: task.categoryID.flatMap { model.categories[$0] },
                    isNext: task.id == next?.id,
                    onToggle: { model.toggleCompleted(task) }
                )
                .card(emphasised: task.id == next?.id)
                .contentShape(Rectangle())
                .onTapGesture { editing = .editing(task) }
                .contextMenu {
                    Button(role: .destructive) {
                        model.delete(task)
                    } label: {
                        Label("Удалить", systemImage: "trash")
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
    }

    private var addButton: some View {
        Button {
            editing = .creating
        } label: {
            Label("Добавить", systemImage: "plus")
                .font(.headline)
                .padding(.horizontal, 22)
                .padding(.vertical, 13)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().stroke(.white.opacity(0.3), lineWidth: 0.8))
                .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
        }
        .padding(.bottom, 8)
    }

    /// A day either side, because that is how a person flicks through a week.
    private var daySwipe: some Gesture {
        DragGesture(minimumDistance: 24)
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                dragOffset = value.translation.width
            }
            .onEnded { value in
                let step = value.translation.width < -60 ? 1 : (value.translation.width > 60 ? -1 : 0)
                withAnimation(.snappy) {
                    dragOffset = 0
                    if step != 0 {
                        model.day = Calendar.current.date(
                            byAdding: .day, value: step, to: model.day
                        ) ?? model.day
                    }
                }
            }
    }
}

/// The week, so moving a few days is one tap rather than several swipes.
struct WeekStrip: View {
    @Binding var selected: Date
    private let calendar = Calendar.current

    var body: some View {
        HStack(spacing: 6) {
            ForEach(days, id: \.self) { day in
                let isSelected = calendar.isDate(day, inSameDayAs: selected)
                let isToday = calendar.isDateInToday(day)

                Button {
                    withAnimation(.snappy) { selected = day }
                } label: {
                    VStack(spacing: 3) {
                        Text(day.formatted(.dateTime.weekday(.abbreviated)))
                            .font(.caption2)
                            .textCase(.lowercase)
                            .foregroundStyle(.secondary)
                        Text(day.formatted(.dateTime.day()))
                            .font(.subheadline.weight(isSelected ? .bold : .regular))
                            .monospacedDigit()
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(.regularMaterial)
                        } else if isToday {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(.primary.opacity(0.25), lineWidth: 1)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// The week the chosen day falls in.
    private var days: [Date] {
        guard let week = calendar.dateInterval(of: .weekOfYear, for: selected) else { return [] }
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: week.start) }
    }
}

/// One task.
struct TaskCard: View {
    let task: CalendarTask
    let category: TaskCategory?
    let isNext: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onToggle) {
                Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(isNext ? .title2 : .title3)
                    .foregroundStyle(task.isCompleted ? .green : accent)
                    .symbolEffect(.bounce, value: task.isCompleted)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 3) {
                Text(task.title)
                    .font(isNext ? .headline : .body)
                    .strikethrough(task.isCompleted)
                    .foregroundStyle(task.isCompleted ? .secondary : .primary)
                    .lineLimit(2)

                HStack(spacing: 8) {
                    if let place = task.locationName, !place.isEmpty {
                        Label(place, systemImage: travelSymbol)
                            .labelStyle(.titleAndIcon)
                    }
                    if let category {
                        Text(category.name)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Color(hex: category.colorHex).opacity(0.25), in: Capsule())
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 2) {
                if let startsAt = task.startsAt {
                    Text(startsAt, style: .time)
                        .font((isNext ? Font.title3 : Font.subheadline).weight(.medium))
                        .monospacedDigit()
                    if isNext && !task.isCompleted {
                        Text(startsAt, style: .relative)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } else if task.isAllDay {
                    Text("весь день")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .overlay(alignment: .leading) {
            if let category {
                Capsule()
                    .fill(Color(hex: category.colorHex))
                    .frame(width: 3)
                    .offset(x: -Theme.cardPadding + 4)
            }
        }
    }

    private var accent: Color {
        category.map { Color(hex: $0.colorHex) } ?? .accentColor
    }

    private var travelSymbol: String {
        switch task.travelMode {
        case .none: "mappin"
        case .walking: "figure.walk"
        case .driving: "car.fill"
        case .transit: "tram.fill"
        }
    }
}

/// The only thing the interface says about the network.
///
/// Not an error, not an alert. Network failures are handled in the background;
/// the person sees a small mark meaning "this has not reached the other phone
/// yet" and carries on, because what is in front of them is the truth either way.
struct SyncIndicator: View {
    let status: SyncStatus

    var body: some View {
        if status.hasUnsyncedChanges {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.caption)
                .foregroundStyle(.secondary)
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
