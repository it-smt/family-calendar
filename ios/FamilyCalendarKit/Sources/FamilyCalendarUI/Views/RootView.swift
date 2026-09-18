import FamilyCalendarKit
import SwiftUI

/// The app: four things, because there are only four things.
public struct RootView: View {
    private let environment: AppEnvironment

    public init(environment: AppEnvironment) {
        self.environment = environment
    }

    public var body: some View {
        TabView {
            DayView(environment: environment)
                .tabItem { Label("Day", systemImage: "calendar") }

            ShoppingListView(environment: environment)
                .tabItem { Label("Shopping", systemImage: "cart") }

            ActivityFeedView(environment: environment)
                .tabItem { Label("Changes", systemImage: "clock.arrow.circlepath") }

            SettingsView(environment: environment)
                .tabItem { Label("Setup", systemImage: "gearshape") }
        }
    }
}

/// Categories, packing lists, and the invite code to read out.
public struct SettingsView: View {
    private let environment: AppEnvironment

    public init(environment: AppEnvironment) {
        self.environment = environment
    }

    public var body: some View {
        NavigationStack {
            List {
                NavigationLink {
                    CategoriesView(environment: environment)
                } label: {
                    Label("Categories", systemImage: "tag")
                }

                NavigationLink {
                    PackingTemplatesView(environment: environment)
                } label: {
                    Label("What to bring", systemImage: "bag")
                }

                Section {
                    LabeledContent("Not synchronised", value: "\(environment.status.pendingChanges)")
                    if let lastSynced = environment.status.lastSyncedAt {
                        LabeledContent("Last sync") {
                            Text(lastSynced, format: .relative(presentation: .named))
                        }
                    }
                } footer: {
                    Text("Everything works offline. This is only how far behind the other phone is.")
                }
            }
            .navigationTitle("Setup")
        }
    }
}
