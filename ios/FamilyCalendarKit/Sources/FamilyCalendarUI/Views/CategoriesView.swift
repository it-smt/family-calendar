import FamilyCalendarKit
import OSLog
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// Managing categories. Colour and a name, nothing more.
public struct CategoriesView: View {
    @State private var categories: [TaskCategory] = []
    @State private var newName: String = ""
    @State private var newColor: Color = .blue
    @State private var observation: Task<Void, Never>?

    private let environment: AppEnvironment

    public init(environment: AppEnvironment) {
        self.environment = environment
    }

    public var body: some View {
        List {
            Section {
                ForEach(categories) { category in
                    HStack {
                        Circle().fill(Color(hex: category.colorHex)).frame(width: 14)
                        Text(category.name)
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            try? environment.categories.delete(category)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }

            Section("New") {
                TextField("Name", text: $newName)
                ColorPicker("Colour", selection: $newColor, supportsOpacity: false)
                Button("Add") {
                    try? environment.categories.create(
                        name: newName.trimmingCharacters(in: .whitespaces),
                        colorHex: newColor.hexString,
                        icon: nil
                    )
                    newName = ""
                }
                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .navigationTitle("Categories")
        .task {
            guard observation == nil else { return }
            observation = Task {
                do {
                    for try await value in environment.categories.observeAll() {
                        categories = value
                    }
                } catch {
                    Log.database.error("category observation ended: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        .onDisappear {
            observation?.cancel()
            observation = nil
        }
    }
}

extension Color {
    /// `#RRGGBB`, the format the categories are stored in.
    var hexString: String {
        #if canImport(UIKit)
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        UIColor(self).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return String(
            format: "#%02X%02X%02X",
            Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded())
        )
        #else
        return "#8E8E93"
        #endif
    }
}
