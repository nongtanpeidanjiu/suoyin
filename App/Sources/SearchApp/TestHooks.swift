import Foundation

/// 只为测试准备的入口（启动参数、分布式通知、调试日志）的总开关。
///
/// 打开的条件：应用包的 Info.plist 里 `FSTestHooksEnabled` 为真（预览版由
/// `Tools/bundle.sh` 写入），或者进程不在 `.app` 包里运行（`swift run`、
/// 直接运行 `.build/debug/SearchApp`）。正式版两者都不满足，所有测试入口
/// 都不生效：参数被忽略、通知不注册、调试日志不写。
enum TestHooks {
    static let enabled: Bool = {
        let bundle = Bundle.main
        if bundle.bundleURL.pathExtension.lowercased() != "app" { return true }
        return bundle.object(forInfoDictionaryKey: "FSTestHooksEnabled") as? Bool == true
    }()

    /// 开关打开且带了这个启动参数。
    static func flag(_ name: String) -> Bool {
        enabled && CommandLine.arguments.contains(name)
    }

    /// 开关打开时，这个启动参数后面跟着的值。
    static func value(after name: String) -> String? {
        guard enabled, let index = CommandLine.arguments.firstIndex(of: name),
              CommandLine.arguments.indices.contains(index + 1) else { return nil }
        return CommandLine.arguments[index + 1]
    }

    /// 环境变量 `FILESEARCH_DEBUG_LOG` 指定的调试日志路径，开关关闭时为空。
    static var debugLogPath: String? {
        guard enabled else { return nil }
        return ProcessInfo.processInfo.environment["FILESEARCH_DEBUG_LOG"]
    }
}
