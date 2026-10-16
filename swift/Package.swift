// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "erupt-sdk",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "EruptSDK", targets: ["EruptSDK"]),
        // SQLite storage through the system libsqlite3; the core library depends on nothing
        .library(name: "EruptSQLite", targets: ["EruptSQLite"]),
    ],
    targets: [
        .target(name: "EruptSDK"),
        .systemLibrary(name: "CSQLite", providers: [.apt(["libsqlite3-dev"]), .brew(["sqlite"])]),
        .target(name: "EruptSQLite", dependencies: ["EruptSDK", "CSQLite"]),
        .executableTarget(name: "erupt-gen-types", dependencies: ["EruptSDK"], path: "Sources/GenTypes"),
        .executableTarget(name: "Blog", dependencies: ["EruptSDK", "EruptSQLite"], path: "Examples/Blog"),
        .executableTarget(name: "Conformance", dependencies: ["EruptSDK"], path: "Examples/Conformance"),
        .testTarget(name: "EruptSDKTests", dependencies: ["EruptSDK", "EruptSQLite"]),
    ]
)
