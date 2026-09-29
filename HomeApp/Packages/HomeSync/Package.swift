// swift-tools-version:5.10
import PackageDescription

// HomeSync — CloudKit sync via CKSyncEngine: coordinator, record mappers, merge policy, orphan parking (depends on HomeStore).
// Skeleton laid by the foundation pass; see HomeApp/CONTRACT.md for the protocols this package implements.
let package = Package(
    name: "HomeSync",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "HomeSync", targets: ["HomeSync"]),
    ],
    dependencies: [
        .package(path: "../HomeStore"),
        .package(path: "../HomeCore"),
    ],
    targets: [
        .target(name: "HomeSync", dependencies: [.product(name: "HomeStore", package: "HomeStore"), .product(name: "HomeCore", package: "HomeCore")]),
        .testTarget(name: "HomeSyncTests", dependencies: ["HomeSync", .product(name: "HomeCoreTesting", package: "HomeCore")]),
    ],
    swiftLanguageVersions: [.v5]
)
