import FamilyCalendarKit
import SwiftUI

/// Четыре вкладки, потому что дел всего четыре.
public struct RootView: View {
    private let environment: AppEnvironment

    public init(environment: AppEnvironment) {
        self.environment = environment
    }

    public var body: some View {
        TabView {
            DayView(environment: environment)
                .tabItem { Label("День", systemImage: "calendar") }

            ShoppingListView(environment: environment)
                .tabItem { Label("Покупки", systemImage: "cart") }

            ActivityFeedView(environment: environment)
                .tabItem { Label("Изменения", systemImage: "clock.arrow.circlepath") }

            SettingsView(environment: environment)
                .tabItem { Label("Настройки", systemImage: "gearshape") }
        }
    }
}

/// Категории, шаблоны сборов и код приглашения, который нужно продиктовать.
public struct SettingsView: View {
    private let environment: AppEnvironment

    public init(environment: AppEnvironment) {
        self.environment = environment
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 10) {
                    NavigationLink {
                        CategoriesView(environment: environment)
                    } label: {
                        row("Категории", systemImage: "tag")
                    }
                    .buttonStyle(.plain)

                    NavigationLink {
                        PackingTemplatesView(environment: environment)
                    } label: {
                        row("Что взять с собой", systemImage: "bag")
                    }
                    .buttonStyle(.plain)

                    VStack(alignment: .leading, spacing: 8) {
                        LabeledContent("Не отправлено") {
                            Text("\(environment.status.pendingChanges)").monospacedDigit()
                        }
                        if let lastSynced = environment.status.lastSyncedAt {
                            LabeledContent("Синхронизация") {
                                Text(lastSynced, format: .relative(presentation: .named))
                            }
                        }
                        Text("Всё работает без сети. Это только про то, насколько отстал второй телефон.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .card()

                    if !AppDatabase.isSharedWithWidget {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("Виджет не видит эти данные", systemImage: "exclamationmark.triangle")
                                .font(.subheadline)
                                .foregroundStyle(.orange)
                            Text("""
                                App Group выключен, поэтому база лежит в контейнере \
                                приложения. Здесь работает всё; виджету просто неоткуда \
                                читать.
                                """)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .card()
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .themedScreen()
            .navigationTitle("Настройки")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func row(_ title: String, systemImage: String) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .card()
    }
}
