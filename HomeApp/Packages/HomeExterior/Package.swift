// swift-tools-version:5.10
import PackageDescription

// HomeExterior — Exterior seeding: geocoding, building footprint (Home server or Overpass), satellite snapshot, yard zones (depends on PlanKit + HomeCore).
// Skeleton laid by the foundation pass; see HomeApp/CONTRACT.md for the protocols this package implements.
let package = Package(
    name: "HomeExterior",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "HomeExterior", targets: ["HomeExterior"]),
    ],
    dependencies: [
        .package(path: "../PlanKit"),
        .package(path: "../HomeCore"),
    ],
    targets: [
        .target(name: "HomeExterior", dependencies: [.product(name: "PlanKit", package: "PlanKit"), .product(name: "HomeCore", package: "HomeCore")]),
        .testTarget(name: "HomeExteriorTests", dependencies: ["HomeExterior", .product(name: "HomeCoreTesting", package: "HomeCore")]),
    ],
    swiftLanguageVersions: [.v5]
)
