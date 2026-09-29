// swift-tools-version:5.10
import PackageDescription

// PlanCanvas — SwiftUI Canvas floor-plan renderer, viewport/gestures, lenses and overlays (depends on PlanKit + HomeCore only).
// Skeleton laid by the foundation pass; see HomeApp/CONTRACT.md for the protocols this package implements.
let package = Package(
    name: "PlanCanvas",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "PlanCanvas", targets: ["PlanCanvas"]),
    ],
    dependencies: [
        .package(path: "../PlanKit"),
        .package(path: "../HomeCore"),
    ],
    targets: [
        .target(name: "PlanCanvas", dependencies: [.product(name: "PlanKit", package: "PlanKit"), .product(name: "HomeCore", package: "HomeCore")]),
        .testTarget(name: "PlanCanvasTests", dependencies: ["PlanCanvas", .product(name: "HomeCoreTesting", package: "HomeCore")]),
    ],
    swiftLanguageVersions: [.v5]
)
