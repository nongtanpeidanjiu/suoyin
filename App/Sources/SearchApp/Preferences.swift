import AppKit

/// Interface preferences kept in the user defaults.
enum Preferences {
    // A new key: the earlier "includeSystemFiles" defaulted to off, and every
    // file is meant to be found unless the user turns this off.
    private static let systemFilesKey = "showSystemAndHiddenFiles"
    private static let dockIconKey = "showDockIcon"

    /// Posted on the main thread when a preference that affects searching changes.
    static let searchOptionsChanged = Notification.Name("SearchOptionsChanged")

    static var includeSystemFiles: Bool {
        get { UserDefaults.standard.object(forKey: systemFilesKey) as? Bool ?? true }
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
        case .ready: return "索引已就绪，共 \(count) 个项目"
        case .recovering: return "正在更新索引，共 \(count) 个项目"
        case .supplementing(let name, let indexed, let restoring):
            return IndexPhase.supplementingLine(name, indexed, restoring: restoring)
        case .failed(let failure): return "索引出错：" + failure.text(.index)
        case .waitingForSetup: return IndexPhase.waitingLine
        case .unavailable(let reason): return reason
        }
    }

    /// The menu's status line: as `summary`, but an index error only by its
    /// title, the explanation being one click away in the settings.
    var menuLine: String {
        if case .failed(let failure) = phase { return "\(failure.title)，结果可能不全" }
        return summary
    }

    var isBusy: Bool {
        switch phase {
        case .starting, .scanning, .recovering: return true
        default: return false
        }
    }
}

extension IndexPhase {
    static let waitingLine = "完成设置后开始建立索引"

    /// Whether the core is running and can be searched.
    var isSearchable: Bool {
        switch self {
        case .starting, .waitingForSetup, .unavailable: return false
        default: return true
        }
    }

    var isUnavailable: Bool {
        if case .unavailable = self { return true }
        return false
    }

    /// The running index stopped with an error.
    var failure: IndexFailure? {
        if case .failed(let failure) = self { return failure }
        return nil
    }

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
