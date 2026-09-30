// swift-tools-version:5.10
import PackageDescription

// HomeStore — GRDB persistence: schema, migrations, repositories, outbox, FTS5 search, rollups, CSV export (depends on HomeCore + GRDB).
// Skeleton laid by the foundation pass; see HomeApp/CONTRACT.md for the protocols this package implements.
let package = Package(
    name: "HomeStore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "HomeStore", targets: ["HomeStore"]),
    ],
    dependencies: [
        .package(path: "../HomeCore"),
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
    ],
    targets: [
        .target(name: "HomeStore", dependencies: [.product(name: "HomeCore", package: "HomeCore"), .product(name: "GRDB", package: "GRDB.swift")]),
        .testTarget(name: "HomeStoreTests", dependencies: ["HomeStore", .product(name: "HomeCoreTesting", package: "HomeCore"),
                                                  .product(name: "GRDB", package: "GRDB.swift")]),
    ],
    swiftLanguageVersions: [.v5]
)
