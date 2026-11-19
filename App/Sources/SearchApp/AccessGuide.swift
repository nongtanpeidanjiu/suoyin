import AppKit

/// Detects Full Disk Access. The setup guide (SetupGuide.swift) walks the
/// user through granting it.
enum DiskAccess {
    /// The privacy database is readable only with Full Disk Access, so an
    /// open attempt tells the two states apart without touching user files.
    static var isGranted: Bool {
        // For looking at the not-yet-granted screens in demo mode only.
        if simulatesMissingAccess { return false }
        let path = NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db"
        let descriptor = open(path, O_RDONLY)
        guard descriptor >= 0 else { return false }
        close(descriptor)
        return true
    }

    private static let simulatesMissingAccess = TestHooks.flag("--demo")
        && TestHooks.flag("--simulate-no-access")

    static func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// 这个软件给人看的名字。内部标识（包标识、数据目录、通知名等）不随它变。
enum AppName {
    static let short = "索隐"

    /// 访达和系统设置的“完整磁盘访问权限”列表里实际显示的名字（预览版为
    /// “索隐（预览）”），授权引导据此提示用户去找哪一项，免得两边对不上。
    /// 不在 .app 包里运行时用正式名称。
    static var displayed: String {
        let bundle = Bundle.main
        guard bundle.bundleURL.pathExtension.lowercased() == "app" else { return short }
        var name = FileManager.default.displayName(atPath: bundle.bundlePath)
        if name.lowercased().hasSuffix(".app") { name = String(name.dropLast(4)) }
        return name.isEmpty ? short : name
    }
}
