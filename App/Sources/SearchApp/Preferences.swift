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
        case .supplementing(let name, let indexed, let restoring):
            return IndexPhase.supplementingLine(name, indexed, restoring: restoring)
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

extension IndexPhase {
    /// "正在补充 <名称>，已收录 <数量> 个", written like the first build's
    /// "正在建立索引，已收录 <数量> 个"; without the count while it is 0.
    /// While a volume brings back an earlier run's entries the line says
    /// that they can be searched already: "正在恢复 <名称> 上次收录的内容，
    /// <数量> 个已可搜索".
    static func supplementingLine(_ name: String, _ indexed: Int, restoring: Bool) -> String {
        if restoring {
            return indexed > 0 ? "正在恢复 \(name) 上次收录的内容，\(formattedCount(indexed)) 个已可搜索"
                : "正在恢复 \(name) 上次收录的内容"
        }
        return indexed > 0 ? "正在补充 \(name)，已收录 \(formattedCount(indexed)) 个" : "正在补充 \(name)"
    }
}

/// A count with thousands separators, as everywhere in the interface.
func formattedCount(_ number: Int) -> String {
    NumberFormatter.localizedString(from: NSNumber(value: number), number: .decimal)
}
