// swift-tools-version:5.10
import PackageDescription

// HomeCapture — Plan capture paths (RoomPlan import, photo trace, rough-in, blocks) and receipt OCR, all producing PlanDraft (depends on PlanKit + HomeCore).
// Skeleton laid by the foundation pass; see HomeApp/CONTRACT.md for the protocols this package implements.
let package = Package(
    name: "HomeCapture",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "HomeCapture", targets: ["HomeCapture"]),
    ],
    dependencies: [
        .package(path: "../PlanKit"),
        .package(path: "../HomeCore"),
    ],
    targets: [
        .target(name: "HomeCapture", dependencies: [.product(name: "PlanKit", package: "PlanKit"), .product(name: "HomeCore", package: "HomeCore")]),
        .testTarget(name: "HomeCaptureTests", dependencies: ["HomeCapture", .product(name: "HomeCoreTesting", package: "HomeCore")],
                    resources: [.copy("Fixtures")]),
    ],
    swiftLanguageVersions: [.v5]
)
