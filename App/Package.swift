// swift-tools-version: 6.0
import PackageDescription

// The interface layer is its own package so it can evolve without touching
// the core package manifest.
//
// 最低系统版本只在这里写一次：Tools/bundle.sh 从下面这行读出它，写进
// Info.plist 的 LSMinimumSystemVersion。改的时候保持 `.macOS("x.y.z")` 的写法。
let minimumMacOS = "15.7.9"

let package = Package(
    name: "SearchApp",
    platforms: [.macOS(minimumMacOS)],
    dependencies: [
        .package(name: "MacFileSearch", path: ".."),
        // 自动更新。锁定确切版本：Sparkle 官方以二进制框架（xcframework）
        // 发布 SwiftPM 包，`swift build` 不需要 Xcode 就能解析和链接。
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
    ],
    targets: [
        .executableTarget(name: "SearchApp", dependencies: [
            .product(name: "SearchCore", package: "MacFileSearch"),
            .product(name: "Sparkle", package: "Sparkle"),
        ], linkerSettings: [
            // 打包后 Sparkle.framework 在 Contents/Frameworks/ 里（见 Tools/bundle.sh）。
            .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            // 直接运行 .build/*/SearchApp 时也按中文显示系统给的名字（见该文件里的说明）。
            .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
                          "-Xlinker", Context.packageDirectory + "/Tools/debug-Info.plist"]),
        ]),
    ],
    swiftLanguageModes: [.v5]
)
