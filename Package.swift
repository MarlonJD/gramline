// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Gramline",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Gramline", targets: ["Gramline"])],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        .target(name: "DMCore", dependencies: ["CSQLite"]),
        .executableTarget(name: "Gramline", dependencies: ["DMCore"]),
        .testTarget(name: "DMCoreTests", dependencies: ["DMCore"])
    ]
)
