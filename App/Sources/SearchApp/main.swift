import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The real core by default; `--demo` keeps the stand-in data for interface work.
    private let service: SearchService = {
        if !CommandLine.arguments.contains("--demo"), let real = try? CoreSearchService() { return real }
        return DemoSearchService()
    }()
    private var panel: SearchPanelController!
    private var statusItem: NSStatusItem!
    private var hotKey: HotKey?
    private lazy var accessGuide = AccessGuideController { [weak self] in self?.service.recheckAccess() }
    private var spinner: Timer?
    private var angle: CGFloat = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = SearchPanelController(service: service)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = Glyphs.menuBar(.idle)
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityLabel("文件搜索")
            button.toolTip = "文件搜索（⌥⇧空格）"
        }

        hotKey = HotKey.defaultShortcut { [weak self] in self?.panel.toggle(anchor: nil) }

        service.onStatusChange = { [weak self] status in
            DispatchQueue.main.async {
                self?.panel.updateFooter()
                self?.reflect(status)
                self?.noteReadiness(status)
            }
        }
        service.onIndexChange = { [weak self] in
            DispatchQueue.main.async { self?.panel.refresh() }
        }
        service.start()

        // Offer the authorization guide once, on the first launch without access.
        if !DiskAccess.isGranted, !UserDefaults.standard.bool(forKey: "accessGuideShown"),
           !CommandLine.arguments.contains("--show") {
            UserDefaults.standard.set(true, forKey: "accessGuideShown")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.accessGuide.show() }
        }

        // Lets test scripts open the panel the way the shortcut does.
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("dev.local.filesearch.show"),
                                                            object: nil, queue: .main) { [weak self] _ in
            self?.panel.show(anchor: nil)
        }

        if CommandLine.arguments.contains("--show") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                self.panel.show(anchor: nil)
                if let flag = CommandLine.arguments.firstIndex(of: "--query"),
                   CommandLine.arguments.indices.contains(flag + 1) {
                    self.panel.prefill(CommandLine.arguments[flag + 1])
                }
                if let flag = CommandLine.arguments.firstIndex(of: "--snapshot"),
                   CommandLine.arguments.indices.contains(flag + 1) {
                    let path = CommandLine.arguments[flag + 1]
                    var wait = 1.5
                    if let d = CommandLine.arguments.firstIndex(of: "--snapshot-delay"),
                       CommandLine.arguments.indices.contains(d + 1), let seconds = Double(CommandLine.arguments[d + 1]) {
                        wait = seconds
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
                        self.panel.refresh()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.panel.snapshot(to: path) }
                    }
                }
            }
        }
    }

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        let secondary = event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
        if secondary {
            statusItem.menu = makeMenu()
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
            return
        }
        let anchor = statusItem.button?.window?.frame
        panel.toggle(anchor: anchor)
    }

    func applicationWillTerminate(_ notification: Notification) {
        service.stop()
    }

    private var wasSearchable = false

    /// Results typed in before the index finished loading appear once it is ready.
    private func noteReadiness(_ status: IndexStatus) {
        var searchable = true
        if case .starting = status.phase { searchable = false }
        if searchable && !wasSearchable { panel.refresh() }
        wasSearchable = searchable
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "打开搜索", action: #selector(openSearch), keyEquivalent: "").target = self
        menu.addItem(.separator())
        let status = NSMenuItem(title: statusLine(), action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())
        if !DiskAccess.isGranted {
            menu.addItem(withTitle: "授予完整磁盘访问权限…", action: #selector(showAccessGuide), keyEquivalent: "").target = self
            menu.addItem(.separator())
        }
        menu.addItem(withTitle: "设置…", action: nil, keyEquivalent: ",")
        menu.addItem(withTitle: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    private func statusLine() -> String {
        let status = service.status
        let count = NumberFormatter.localizedString(from: NSNumber(value: status.indexedCount), number: .decimal)
        switch status.phase {
        case .starting: return "正在准备索引"
        case .scanning: return "正在建立索引，已收录 \(count) 个"
        case .ready: return "索引已就绪，共 \(count) 个文件"
        case .supplementing(let volume): return "正在补充 \(volume) 的文件"
        case .degraded(let reason): return reason
        }
    }

    @objc private func showAccessGuide() { accessGuide.show() }

    @objc private func openSearch() {
        panel.show(anchor: statusItem.button?.window?.frame)
    }

    private func reflect(_ status: IndexStatus) {
        switch status.phase {
        case .starting, .scanning:
            guard spinner == nil else { return }
            if Motion.reduced {
                statusItem.button?.image = Glyphs.menuBar(.indexing(angle: 0))
                return
            }
            spinner = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.angle += 2 * .pi / (1.2 * 20)
                self.statusItem.button?.image = Glyphs.menuBar(.indexing(angle: self.angle))
            }
        case .ready, .supplementing:
            spinner?.invalidate()
            spinner = nil
            statusItem.button?.image = Glyphs.menuBar(.idle)
        case .degraded:
            spinner?.invalidate()
            spinner = nil
            statusItem.button?.image = Glyphs.menuBar(.attention)
        }
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
// `--regular` gives the preview a Dock icon so that testing tools can see it.
application.setActivationPolicy(CommandLine.arguments.contains("--regular") ? .regular : .accessory)
application.run()
