// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FamilyCalendarKit",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "FamilyCalendarKit", targets: ["FamilyCalendarKit"]),
        .library(name: "FamilyCalendarUI", targets: ["FamilyCalendarUI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0")
    ],
    targets: [
        .target(
            name: "FamilyCalendarKit",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
            resources: [.copy("Database/SQL")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Views and view models. Kept in the package so the app target is a
        // shell, and so this layer can be built without Xcode.
        .target(
            name: "FamilyCalendarUI",
            dependencies: ["FamilyCalendarKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "FamilyCalendarKitTests",
            dependencies: ["FamilyCalendarKit"],
            // The same fixtures the server's test suite checks against
            // python-dateutil.
            resources: [.process("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
