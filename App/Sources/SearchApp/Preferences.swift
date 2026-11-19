import AppKit

/// Interface preferences kept in the user defaults.
enum Preferences {
    private static let systemFilesKey = "includeSystemFiles"
    private static let dockIconKey = "showDockIcon"

    /// Posted on the main thread when a preference that affects searching changes.
    static let searchOptionsChanged = Notification.Name("SearchOptionsChanged")

    static var includeSystemFiles: Bool {
        get { UserDefaults.standard.bool(forKey: systemFilesKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: systemFilesKey)
            NotificationCenter.default.post(name: searchOptionsChanged, object: nil)
        }
    }

    static var showDockIcon: Bool {
        get { UserDefaults.standard.bool(forKey: dockIconKey) }
        set { UserDefaults.standard.set(newValue, forKey: dockIconKey) }
    }
}

extension IndexStatus {
    /// One line describing the index, shared by the menu and the settings window.
    var summary: String {
        let count = NumberFormatter.localizedString(from: NSNumber(value: indexedCount), number: .decimal)
        switch phase {
        case .starting: return "正在准备索引"
        case .scanning: return "正在建立索引，已收录 \(count) 个"
        case .ready: return "索引已就绪，共 \(count) 个文件"
        case .recovering: return "正在更新索引，共 \(count) 个文件"
        case .supplementing(let volume): return "正在补充 \(volume) 的文件"
        case .degraded(let reason): return reason
        }
    }

    var isBusy: Bool {
        switch phase {
        case .starting, .scanning, .recovering: return true
        default: return false
        }
    }
}
