import AppKit
import Sparkle

/// 自动更新（Sparkle 2）的薄封装。
///
/// 只有应用包的 Info.plist 里同时有 `SUFeedURL` 和 `SUPublicEDKey` 时才启用
/// （正式版由 `Tools/bundle.sh --release` 写入；预览版缺公钥就不写），否则
/// `Updater.shared` 为空，菜单和设置里的更新功能整个隐藏。
///
/// 隐私：只在检查更新时联网，请求里不带任何用户或机器标识。Info.plist 写了
/// `SUEnableSystemProfiling = false`，这里再把 `sendsSystemProfile` 设为假、
/// 不允许任何系统信息键、不追加任何查询参数，三重保证不上报系统信息。
///
/// 演示模式（`--demo`）下更新器不启动，不会联网；设置里照常显示这一组，
/// 但“立即检查更新”不可用。
final class Updater: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate, NSMenuItemValidation {
    /// 更新方式三档。存储方式与 Sparkle 设置的对应关系：
    ///
    /// - `.automatic`（自动下载并安装）：
    ///   `automaticallyDownloadsUpdates = true`，本应用的 `updateAsksBeforeInstalling = false`。
    ///   Sparkle 在后台下载，下次退出本应用时静默安装，不弹任何窗口
    ///   （代理 `willInstallUpdateOnQuit` 返回 false，交给 Sparkle 自己安排）。
    /// - `.askBeforeInstalling`（自动下载，安装前询问，默认）：
    ///   `automaticallyDownloadsUpdates = true`，`updateAsksBeforeInstalling = true`。
    ///   下载好后代理 `willInstallUpdateOnQuit` 返回 true、接管安装时机，立刻
    ///   弹出本应用自己的询问框：“立即安装并重新打开”或“稍后”。注意 Sparkle
    ///   的规定：已下载的更新在退出时一定会安装，无法拒绝，所以“稍后”的意思是
    ///   “下次退出时安装”，询问框上照实写明。
    /// - `.notifyOnly`（只提醒有新版，不自动下载）：
    ///   `automaticallyDownloadsUpdates = false`。Sparkle 发现新版本时弹出它的
    ///   标准提示窗口，用户点“安装更新”后才下载。
    ///
    /// “自动检查更新”总开关对应 `automaticallyChecksForUpdates`；关闭后三档都
    /// 不起作用，只能在菜单或设置里手动检查。Info.plist 的默认值是
    /// `SUEnableAutomaticChecks = true`、`SUAutomaticallyUpdate = true`，再加上
    /// `updateAsksBeforeInstalling` 缺省为真，合起来就是默认的第二档；因为
    /// Info.plist 里已经写明是否自动检查，Sparkle 不会在第二次启动时弹窗询问。
    enum Mode: Int, CaseIterable {
        case automatic, askBeforeInstalling, notifyOnly

        var title: String {
            switch self {
            case .automatic: return "自动下载并安装"
            case .askBeforeInstalling: return "自动下载，安装前询问"
            case .notifyOnly: return "只提醒有新版，不自动下载"
            }
        }
    }

    /// 设置界面要跟着变化的通知（检查开始或结束、上次检查时间、待安装的更新）。
    static let stateChanged = Notification.Name("UpdaterStateChanged")

    /// 没启用更新功能时为空。
    static let shared: Updater? = isAvailable ? Updater() : nil

    /// 包里有更新公钥和更新清单地址（或测试用的 `--feed-url`）。
    static let isAvailable: Bool = {
        let info = Bundle.main.infoDictionary ?? [:]
        let key = (info["SUPublicEDKey"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        let feed = (info["SUFeedURL"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        return !key.isEmpty && (!feed.isEmpty || feedOverride != nil)
    }()

    /// 向导欢迎页等处的联网说明：启用更新时只在检查更新时联网，否则完全不联网。
    static var networkPromise: String {
        isAvailable ? "只在检查更新时联网，不上传任何信息。" : "不上传任何信息，不联网。"
    }

    /// 测试入口 `--feed-url <地址>`：改从这个地址读更新清单（例如本机的
    /// appcast），只在测试开关打开时生效。
    private static let feedOverride: String? = TestHooks.value(after: "--feed-url")

    private static let asksKey = "updateAsksBeforeInstalling"

    /// 演示模式不联网：更新器不启动。
    let isOffline = TestHooks.flag("--demo")

    private var controller: SPUStandardUpdaterController!
    private var observations: [NSKeyValueObservation] = []
    /// 第二档下已下载好、等用户决定的更新：版本号和立即安装的入口。
    private(set) var pendingVersion: String?
    private var installNow: (() -> Void)?

    private override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self,
                                                  userDriverDelegate: self)
        let updater = controller.updater
        updater.sendsSystemProfile = false
        if !isOffline { controller.startUpdater() }
        for path in [\SPUUpdater.canCheckForUpdates, \SPUUpdater.sessionInProgress] {
            observations.append(updater.observe(path) { _, _ in Self.post() })
        }
        observations.append(updater.observe(\.lastUpdateCheckDate) { _, _ in Self.post() })
    }

    private static func post() {
        DispatchQueue.main.async { NotificationCenter.default.post(name: stateChanged, object: nil) }
    }

    private var updater: SPUUpdater { controller.updater }

    // MARK: 设置

    var automaticallyChecks: Bool {
        get { updater.automaticallyChecksForUpdates }
        set { updater.automaticallyChecksForUpdates = newValue }
    }

    var mode: Mode {
        get {
            guard updater.automaticallyDownloadsUpdates else { return .notifyOnly }
            let asks = UserDefaults.standard.object(forKey: Self.asksKey) as? Bool ?? true
            return asks ? .askBeforeInstalling : .automatic
        }
        set {
            updater.automaticallyDownloadsUpdates = newValue != .notifyOnly
            if newValue != .notifyOnly {
                UserDefaults.standard.set(newValue == .askBeforeInstalling, forKey: Self.asksKey)
            }
        }
    }

    var canCheck: Bool { !isOffline && updater.canCheckForUpdates }
    var isChecking: Bool { updater.sessionInProgress }
    var lastCheck: Date? { updater.lastUpdateCheckDate }

    /// 当前版本，例如“0.1.0（42）”。
    static var currentVersion: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "?"
        guard let build = info["CFBundleVersion"] as? String, !build.isEmpty else { return short }
        return "\(short)（\(build)）"
    }

    /// 菜单项“检查更新…”和设置里的按钮：有待安装的更新就安装，否则检查。
    @objc func checkForUpdates() {
        if let installNow {
            install(installNow)
            return
        }
        guard canCheck else { return }
        controller.checkForUpdates(nil)
    }

    /// 菜单里这一项的文字。
    var menuTitle: String {
        if let pendingVersion { return "安装更新 \(pendingVersion) 并重新打开…" }
        return "检查更新…"
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        installNow != nil || canCheck
    }

    private func install(_ handler: @escaping () -> Void) {
        installNow = nil
        pendingVersion = nil
        Self.post()
        handler()
    }

    // MARK: SPUUpdaterDelegate

    func feedURLString(for updater: SPUUpdater) -> String? { Self.feedOverride }

    func feedParameters(for updater: SPUUpdater, sendingSystemProfile sendingProfile: Bool) -> [[String: String]] { [] }

    func allowedSystemProfileKeys(for updater: SPUUpdater) -> [String]? { [] }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        if isOffline {
            throw NSError(domain: "Updater", code: 1, userInfo: [NSLocalizedDescriptionKey: "演示模式不检查更新。"])
        }
    }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        guard mode == .askBeforeInstalling else { return false }
        pendingVersion = item.displayVersionString
        installNow = immediateInstallHandler
        Self.post()
        DispatchQueue.main.async { [weak self] in self?.askToInstall() }
        return true
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        Self.post()
    }

    /// 第二档的询问框。
    private func askToInstall() {
        guard let version = pendingVersion, let handler = installNow else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "\(AppName.short) \(version) 已下载好"
        alert.informativeText = "现在安装会退出并重新打开\(AppName.short)。选择“稍后”，会在下次退出\(AppName.short)时安装。"
        alert.addButton(withTitle: "立即安装并重新打开")
        alert.addButton(withTitle: "稍后")
        if alert.runModal() == .alertFirstButtonReturn { install(handler) }
    }

    // MARK: SPUStandardUserDriverDelegate

    /// 本应用平时只在菜单栏，没有窗口在前台；Sparkle 定时检查到新版本时，
    /// 把应用带到前台再显示它的提示窗口，免得窗口藏在别的应用后面。
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem,
                                                              andInImmediateFocus immediateFocus: Bool) -> Bool { true }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
                                                   state: SPUUserUpdateState) {
        if handleShowingUpdate { NSApp.activate(ignoringOtherApps: true) }
    }
}
