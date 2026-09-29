// swift-tools-version:5.10
import PackageDescription

// PlanKit — pure-Swift 2D geometry for the Home app (LLD §6).
// No Apple-only frameworks: builds and tests with `swift test` on macOS and Linux.
// The LLD's vendored Clipper2 is intentionally dropped; the few polygon operations
// the app needs (overlap area, split, union of adjacent rooms, outward offset) are
// implemented in pure Swift in `Clip.swift`.
let package = Package(
    name: "PlanKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "PlanKit", targets: ["PlanKit"]),
    ],
    targets: [
        .target(name: "PlanKit"),
        .testTarget(name: "PlanKitTests", dependencies: ["PlanKit"]),
    ],
    swiftLanguageVersions: [.v5]
)
