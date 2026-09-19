import FamilyCalendarKit
import OSLog
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// Четыре вкладки, потому что дел всего четыре.
public struct RootView: View {
    @State private var tab: Tab = .day
    private let environment: AppEnvironment

    public init(environment: AppEnvironment) {
        self.environment = environment
    }

    enum Tab: Hashable {
        case day, shopping, feed, settings
    }

    public var body: some View {
        TabView(selection: $tab) {
            DayView(environment: environment)
                .tabItem { Label("День", systemImage: "calendar") }
                .tag(Tab.day)

            ShoppingListView(environment: environment)
                .tabItem { Label("Покупки", systemImage: "cart") }
                .tag(Tab.shopping)

            ActivityFeedView(environment: environment)
                .tabItem { Label("Изменения", systemImage: "clock.arrow.circlepath") }
                .tag(Tab.feed)

            SettingsView(environment: environment)
                .tabItem { Label("Настройки", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        // Панель внизу перекрашивается под открытую вкладку — тот же цвет, что
        // и шапка над ней, поэтому экран читается как один предмет, а не как
        // цветная картинка со стандартной планкой под ней.
        .tint(tint)
    }

    private var tint: Color {
        switch tab {
        case .day: Theme.Hour.at(Date()).gradient.from
        case .shopping: Theme.shoppingGradient.from
        case .feed: Theme.feedGradient.to
        case .settings: Theme.settingsGradient.to
        }
    }
}

/// Категории, шаблоны сборов и то, насколько отстал второй телефон.
public struct SettingsView: View {
    @State private var household: Household?
    @State private var copied = false
    @State private var observation: Task<Void, Never>?

    private let environment: AppEnvironment

    public init(environment: AppEnvironment) {
        self.environment = environment
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    Theme.ScreenHeader("Настройки", gradient: Theme.settingsGradient)

                    VStack(alignment: .leading, spacing: 18) {
                        VStack(spacing: 8) {
                            SectionLabel("Позвать второго")
                            inviteCard
                        }

                        VStack(spacing: 8) {
                            SectionLabel("Что настраивать")
                            NavigationLink {
                                CategoriesView(environment: environment)
                            } label: {
                                row(
                                    "Категории",
                                    detail: "Цвет, по которому видно, чьё это дело",
                                    systemImage: "tag.fill",
                                    tint: Theme.swatchColor(0)
                                )
                            }
                            .buttonStyle(.plain)

                            NavigationLink {
                                PackingTemplatesView(environment: environment)
                            } label: {
                                row(
                                    "Что взять с собой",
                                    detail: "Списки, которые подставляются в задачу",
                                    systemImage: "bag.fill",
                                    tint: Theme.swatchColor(5)
                                )
                            }
                            .buttonStyle(.plain)
                        }

                        VStack(spacing: 8) {
                            SectionLabel("Второй телефон")
                            syncCard
                            if !AppDatabase.isSharedWithWidget {
                                widgetWarning
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 20)
                    .padding(.bottom, 28)
                }
            }
            .headeredScreen()
            .task {
                guard observation == nil else { return }
                observation = Task {
                    do {
                        for try await value in environment.household.observe() {
                            household = value
                        }
                    } catch {
                        Log.database.error(
                            "household observation ended: \(error.localizedDescription, privacy: .public)"
                        )
                    }
                }
            }
            .onDisappear {
                observation?.cancel()
                observation = nil
            }
        }
    }

    /// The invite code, which is the only way the second person gets in.
    ///
    /// It arrives with the first sync; until then there is nothing to show and
    /// saying so is better than showing an empty box.
    private var inviteCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(household?.name ?? "Календарь")
                .font(.body.weight(.medium))

            if let code = household?.inviteCode, !code.isEmpty {
                HStack(spacing: 10) {
                    Text(code)
                        .font(.system(.title3, design: .monospaced).weight(.bold))
                        .kerning(2)
                    Spacer(minLength: 0)
                    Button {
                        copy(code)
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 32, height: 32)
                            .background(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(Theme.swatchColor(6))
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Скопировать код")
                }
                Text("Второй ставит приложение, выбирает «Присоединиться» и вводит этот код.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Код появится после первой синхронизации.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .card(tint: Theme.swatchColor(6))
    }

    private func copy(_ code: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = code
        #endif
        withAnimation(.snappy) { copied = true }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation(.snappy) { copied = false }
        }
    }

    private var syncCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("Не отправлено") {
                Text("\(environment.status.pendingChanges)")
                    .monospacedDigit()
                    .fontWeight(.semibold)
            }
            if let lastSynced = environment.status.lastSyncedAt {
                LabeledContent("Синхронизация") {
                    Text(lastSynced, format: .relative(presentation: .named))
                }
            }
            Divider()
            Text("Всё работает без сети. Это только про то, насколько отстал второй телефон.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .font(.subheadline)
        .card(tint: environment.status.hasUnsyncedChanges ? Theme.swatchColor(1) : Theme.swatchColor(3))
    }

    private var widgetWarning: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Виджет не видит эти данные", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.swatchColor(1))
            Text("""
                App Group выключен, поэтому база лежит в контейнере \
                приложения. Здесь работает всё; виджету просто неоткуда \
                читать.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .card(tint: Theme.swatchColor(1))
    }

    private func row(
        _ title: String, detail: String, systemImage: String, tint: Color
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(tint))

            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.body.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .card(tint: tint)
    }
}
