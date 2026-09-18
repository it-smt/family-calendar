// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FamilyCalendarKit",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "FamilyCalendarKit", targets: ["FamilyCalendarKit"])
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
        .testTarget(
            name: "FamilyCalendarKitTests",
            dependencies: ["FamilyCalendarKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
