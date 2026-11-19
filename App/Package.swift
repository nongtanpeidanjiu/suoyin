// swift-tools-version: 6.0
import PackageDescription

// The interface layer is its own package so it can evolve without touching
// the core package manifest. It will depend on SearchCore (path: "..") once
// the real SearchService implementation is available.
let package = Package(
    name: "SearchApp",
    platforms: [.macOS("15.7.9")],
    dependencies: [.package(name: "MacFileSearch", path: "..")],
    targets: [
        .executableTarget(name: "SearchApp", dependencies: [.product(name: "SearchCore", package: "MacFileSearch")]),
    ],
    swiftLanguageModes: [.v5]
)
