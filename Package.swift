// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "InstaDM",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "InstaDM", targets: ["InstaDM"])],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        .target(name: "DMCore", dependencies: ["CSQLite"]),
        .executableTarget(name: "InstaDM", dependencies: ["DMCore"]),
        .testTarget(name: "DMCoreTests", dependencies: ["DMCore"])
    ]
)
