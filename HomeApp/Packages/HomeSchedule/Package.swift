// swift-tools-version:5.10
import PackageDescription

// HomeSchedule — Local notifications (60-slot planner diffing, BG refresh) and EventKit calendar sync (depends on HomeCore).
// Skeleton laid by the foundation pass; see HomeApp/CONTRACT.md for the protocols this package implements.
let package = Package(
    name: "HomeSchedule",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "HomeSchedule", targets: ["HomeSchedule"]),
    ],
    dependencies: [
        .package(path: "../HomeCore"),
    ],
    targets: [
        .target(name: "HomeSchedule", dependencies: [.product(name: "HomeCore", package: "HomeCore")]),
        .testTarget(name: "HomeScheduleTests", dependencies: ["HomeSchedule", .product(name: "HomeCoreTesting", package: "HomeCore")]),
    ],
    swiftLanguageVersions: [.v5]
)
