// swift-tools-version:5.10
import PackageDescription

// HomeCore — domain models, pure engines and every cross-module protocol (LLD §4, §9, §10, §14).
// HomeCoreTesting — in-memory implementations of every repository/service protocol plus sample data,
// used by SwiftUI previews, unit tests and (until real implementations land) the app's AppEnvironment.
// Both are pure Swift (Foundation only) and test with `swift test` on macOS and Linux.
let package = Package(
    name: "HomeCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "HomeCore", targets: ["HomeCore"]),
        .library(name: "HomeCoreTesting", targets: ["HomeCoreTesting"]),
    ],
    dependencies: [
        .package(path: "../PlanKit"),
    ],
    targets: [
        .target(name: "HomeCore", dependencies: ["PlanKit"]),
        .target(name: "HomeCoreTesting", dependencies: ["HomeCore", "PlanKit"]),
        .testTarget(name: "HomeCoreTests", dependencies: ["HomeCore", "HomeCoreTesting", "PlanKit"]),
    ],
    swiftLanguageVersions: [.v5]
)
