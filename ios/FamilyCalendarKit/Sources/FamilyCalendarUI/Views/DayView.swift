import FamilyCalendarKit
import SwiftUI

/// The day. The screen the app opens on.
public struct DayView: View {
    @State private var model: DayViewModel
    @State private var editing: TaskEditorViewModel.Mode?
    private let environment: AppEnvironment

    public init(environment: AppEnvironment) {
        self.environment = environment
        _model = State(wrappedValue: DayViewModel(environment: environment))
    }

    public var body: some View {
        NavigationStack {
            List {
                if !model.notices.isEmpty {
                    Section {
                        ForEach(model.notices) { notice in
                            SupersededEditRow(
                                notice: notice,
                                onRestore: { model.restore(notice) },
                                onDismiss: { model.dismiss(notice) }
                            )
                        }
                    }
                }

                Section {
                    if model.visibleTasks.isEmpty {
                        ContentUnavailableView(
                            "Nothing planned",
                            systemImage: "checkmark.circle",
                            description: Text("Tap + to add something.")
                        )
                        .listRowBackground(Color.clear)
                    } else {
                        ForEach(model.visibleTasks) { task in
                            TaskRow(task: task, category: task.categoryID.flatMap { model.categories[$0] })
                                .contentShape(Rectangle())
                                .onTapGesture { editing = .editing(task) }
                                .swipeActions(edge: .leading) {
                                    Button {
                                        model.toggleCompleted(task)
                                    } label: {
                                        Label(
                                            task.isCompleted ? "Undo" : "Done",
                                            systemImage: task.isCompleted
                                                ? "arrow.uturn.backward" : "checkmark"
                                        )
                                    }
                                    .tint(.green)
                                }
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) {
                                        model.delete(task)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(model.day.formatted(.dateTime.weekday(.wide).day().month()))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    SyncIndicator(status: environment.status)
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    CategoryFilterMenu(
                        categories: Array(model.categories.values).sorted { $0.name < $1.name },
                        selection: $model.categoryFilter
                    )
                    Button {
                        editing = .creating
                    } label: {
                        Image(systemName: "plus")
                    }
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button {
                        model.day = Calendar.current.date(byAdding: .day, value: -1, to: model.day) ?? model.day
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    Spacer()
                    Button("Today") { model.day = Date() }
                        .disabled(Calendar.current.isDateInToday(model.day))
                    Spacer()
                    Button {
                        model.day = Calendar.current.date(byAdding: .day, value: 1, to: model.day) ?? model.day
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                }
            }
            .sheet(item: $editing) { mode in
                TaskEditorView(environment: environment, mode: mode, day: model.day)
            }
            // A pull to refresh is a courtesy, not a requirement: the list is
            // already showing the truth, and this only asks the engine to try.
            .refreshable { environment.syncNow() }
            .task { model.onAppear() }
            .onDisappear { model.onDisappear() }
        }
    }
}

/// One task in the list.
struct TaskRow: View {
    let task: CalendarTask
    let category: Category?

    var body: some View {
        HStack(spacing: 12) {
            Rectangle()
                .fill(category.map { Color(hex: $0.colorHex) } ?? .clear)
                .frame(width: 3)
                .clipShape(.capsule)

            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .strikethrough(task.isCompleted)
                    .foregroundStyle(task.isCompleted ? .secondary : .primary)

                if let notes = task.notes, !notes.isEmpty {
                    Text(notes)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if task.travelMode != .none {
                Image(systemName: travelSymbol)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let startsAt = task.startsAt {
                Text(startsAt.formatted(date: .omitted, time: .shortened))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else if task.isAllDay {
                Text("All day")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var travelSymbol: String {
        switch task.travelMode {
        case .none: "circle"
        case .walking: "figure.walk"
        case .driving: "car.fill"
        case .transit: "tram.fill"
        }
    }
}

/// The only thing the UI says about the network.
///
/// Not an error, not an alert. Network failures are handled in the background;
/// the person sees a small mark meaning "this has not reached the other phone
/// yet" and carries on, because what is in front of them is the truth either way.
struct SyncIndicator: View {
    let status: SyncStatus

    var body: some View {
        if status.hasUnsyncedChanges {
            Label("\(status.pendingChanges)", systemImage: "arrow.triangle.2.circlepath")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel("\(status.pendingChanges) changes not synchronised")
        }
    }
}

struct CategoryFilterMenu: View {
    let categories: [Category]
    @Binding var selection: UUID?

    var body: some View {
        Menu {
            Button("All") { selection = nil }
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
            Image(systemName: selection == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
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

extension Color {
    /// `#RRGGBB` or `#RRGGBBAA`, the format the category colours are stored in.
    init(hex: String) {
        let cleaned = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)

        let red, green, blue, alpha: Double
        if cleaned.count == 8 {
            red = Double((value >> 24) & 0xFF) / 255
            green = Double((value >> 16) & 0xFF) / 255
            blue = Double((value >> 8) & 0xFF) / 255
            alpha = Double(value & 0xFF) / 255
        } else {
            red = Double((value >> 16) & 0xFF) / 255
            green = Double((value >> 8) & 0xFF) / 255
            blue = Double(value & 0xFF) / 255
            alpha = 1
        }
        self.init(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }
}
