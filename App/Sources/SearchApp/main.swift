import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The real core by default; `--demo` keeps the stand-in data for interface
    /// work. `--data-dir <path>` points the core at another data directory, so
    /// tests that change the index leave the user's own alone.
    private let service: SearchService = {
        if !CommandLine.arguments.contains("--demo"),
           let real = try? CoreSearchService(dataDirectory: AppDelegate.testDataDirectory) { return real }
        return DemoSearchService()
    }()

    private static var testDataDirectory: URL? {
        guard let flag = CommandLine.arguments.firstIndex(of: "--data-dir"),
              CommandLine.arguments.indices.contains(flag + 1) else { return nil }
        let path = (CommandLine.arguments[flag + 1] as NSString).expandingTildeInPath
        return URL(fileURLWithPath: path, isDirectory: true)
    }
    private var panel: SearchPanelController!
    private var statusItem: NSStatusItem!
    private var hotKey: HotKey!
    private var shortcuts: ShortcutCenter!
    private lazy var setupGuide = SetupGuideController(
        service: service, shortcuts: shortcuts,
        onGranted: { [weak self] in self?.service.recheckAccess() },
        onFinish: { [weak self] in self?.panel.show(anchor: nil) })
    private lazy var settings = SettingsWindowController(
        service: service, shortcuts: shortcuts,
        onShowAccessGuide: { [weak self] in self?.setupGuide.show(at: .access) },
        onShowSetupGuide: { [weak self] in self?.setupGuide.show(at: .welcome) })
    private var spinner: Timer?
    /// The status line of the menu while it is open, kept current as the
    /// supplementing count rises.
    private weak var statusMenuItem: NSMenuItem?
    private var angle: CGFloat = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        panel = SearchPanelController(service: service)
        panel.onOpenSettings = { [weak self] in self?.openSettings() }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = Glyphs.menuBar(.idle)
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityLabel("文件搜索")
        }

        hotKey = HotKey { [weak self] in self?.panel.toggle(anchor: nil) }
        shortcuts = ShortcutCenter(hotKey: hotKey)
        shortcuts.onChange = { [weak self] in self?.shortcutsChanged() }
        // Puts right saved shortcuts that clash, then registers the global one.
        shortcuts.start()

        service.onStatusChange = { [weak self] status in
            DispatchQueue.main.async {
                self?.panel.updateFooter()
                self?.reflect(status)
                self?.noteReadiness(status)
                self?.settings.update(status)
                self?.showStatusLine(status)
            }
        }
        service.onIndexChange = { [weak self] in
            DispatchQueue.main.async { self?.panel.refresh() }
        }
        service.onExternalVolumesChange = { [weak self] in
            DispatchQueue.main.async {
                self?.settings.volumesChanged()
                self?.setupGuide.volumesChanged()
            }
        }
        service.start()
        panel.clearPreviewLeftovers()

        // The setup guide opens by itself once, on the first launch. The key
        // is the one the earlier single-page access guide set, so whoever saw
        // that one is not asked again. `--show-setup` opens it regardless,
        // for testing.
        let forced = CommandLine.arguments.contains("--show-setup")
        if forced || (!UserDefaults.standard.bool(forKey: "accessGuideShown") && !CommandLine.arguments.contains("--show")) {
            if !forced { UserDefaults.standard.set(true, forKey: "accessGuideShown") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.setupGuide.show(at: .welcome) }
        }

        // Lets test scripts open the panel the way the shortcut does.
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("dev.local.filesearch.show"),
                                                            object: nil, queue: .main) { [weak self] _ in
            self?.panel.show(anchor: nil)
        }
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("dev.local.filesearch.hide"),
                                                            object: nil, queue: .main) { [weak self] _ in
            self?.panel.hide()
        }
        // Quits the normal way, as the menu's “退出” does, so that tests can
        // check what a restart brings back.
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("dev.local.filesearch.quit"),
                                                            object: nil, queue: .main) { _ in
            NSApp.terminate(nil)
        }
        // Opens the confirmation for deleting a volume's data (object: its
        // id), as its “…” menu does; a pop-up menu cannot be driven by tests.
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("dev.local.filesearch.deleteVolume"),
                                                            object: nil, queue: .main) { [weak self] note in
            guard let id = note.object as? String else { return }
            self?.settings.askToDeleteVolumeForTesting(id)
        }
        // Test hooks for Quick Look: the same path as Option-Space, and the
        // arrow keys (object "1" or "-1").
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("dev.local.filesearch.preview"),
                                                            object: nil, queue: .main) { [weak self] _ in
            self?.panel.togglePreview()
        }
        // Previews a given file (object: its path), e.g. test samples the
        // index has not picked up yet.
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("dev.local.filesearch.previewPath"),
                                                            object: nil, queue: .main) { [weak self] note in
            guard let path = note.object as? String else { return }
            self?.panel.previewPathForTesting(path)
        }
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("dev.local.filesearch.select"),
                                                            object: nil, queue: .main) { [weak self] note in
            self?.panel.moveSelectionForTesting(by: Int(note.object as? String ?? "") ?? 1)
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

    /// Opening the application again (from Finder, Launchpad or the Dock
    /// icon) shows the settings window, since there is no other window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openSettings() }
        return false
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
        let status = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        statusMenuItem = status
        showStatusLine(service.status)
        menu.addItem(.separator())
        if !DiskAccess.isGranted {
            menu.addItem(withTitle: "授予完整磁盘访问权限…", action: #selector(showAccessGuide), keyEquivalent: "").target = self
            menu.addItem(.separator())
        }
        menu.addItem(withTitle: "设置…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    /// Digits of equal width, so a rising count does not make the line shift.
    private func showStatusLine(_ status: IndexStatus) {
        guard let item = statusMenuItem else { return }
        item.attributedTitle = NSAttributedString(string: status.summary, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
            .foregroundColor: NSColor.disabledControlTextColor,
        ])
    }

    @objc func openSettings() {
        panel.hide()
        settings.show()
    }

    func settingsDidChangeDockIcon() { settings.reassert() }

    private func shortcutsChanged() {
        panel.previewShortcut = shortcuts.preview
        let shortcut = shortcuts.registeredGlobal.map { "（\($0.display)）" } ?? ""
        statusItem.button?.toolTip = "文件搜索\(shortcut)"
    }

    /// Not shown while the application has no Dock icon, but it still
    /// provides the standard key equivalents: editing in the search field,
    /// closing the settings window, opening settings and quitting.
    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于文件搜索", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "设置…", action: #selector(openSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let window = NSMenu(title: "窗口")
        window.addItem(withTitle: "关闭", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = window
        main.addItem(windowItem)
        NSApp.mainMenu = main
        NSApp.windowsMenu = window
    }

    @objc private func showAccessGuide() { setupGuide.show(at: .access) }

    @objc private func openSearch() {
        panel.show(anchor: statusItem.button?.window?.frame)
    }

    private func reflect(_ status: IndexStatus) {
        switch status.phase {
        case .starting, .scanning, .recovering:
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

// `--self-test-shortcuts` checks the shortcut rules and exits.
if CommandLine.arguments.contains("--self-test-shortcuts") {
    exit(ShortcutSelfTest.run() ? 0 : 1)
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
// `--regular` gives the preview a Dock icon so that testing tools can see it.
let showsDockIcon = Preferences.showDockIcon || CommandLine.arguments.contains("--regular")
application.setActivationPolicy(showsDockIcon ? .regular : .accessory)
// `--appearance dark` or `light` fixes this application's appearance, so both
// can be checked in screenshots without changing the system setting.
if let flag = CommandLine.arguments.firstIndex(of: "--appearance"), CommandLine.arguments.indices.contains(flag + 1) {
    application.appearance = NSAppearance(named: CommandLine.arguments[flag + 1] == "dark" ? .darkAqua : .aqua)
}
application.run()
