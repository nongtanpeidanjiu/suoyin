// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacFileSearch",
    platforms: [.macOS("15.7.9")],
    products: [
        .library(name: "SearchCore", targets: ["SearchCore"]),
        .executable(name: "file-search", targets: ["SearchCLI"]),
    ],
    targets: [
        .target(name: "DarwinMetadata"),
        .target(name: "SearchCore", dependencies: ["DarwinMetadata"]),
        .executableTarget(name: "SearchCLI", dependencies: ["SearchCore"]),
        .testTarget(name: "SearchCoreTests", dependencies: ["SearchCore"]),
    ],
    swiftLanguageModes: [.v5]
)
