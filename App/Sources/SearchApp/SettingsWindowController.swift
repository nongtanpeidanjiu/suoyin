import AppKit
import ServiceManagement

/// The standard settings window: toolbar tabs at the top, one form per tab.
final class SettingsWindowController: NSObject, NSWindowDelegate, NSToolbarDelegate {
    private static let width: CGFloat = 560
    private static let paneKey = "settingsPane"

    private let general: GeneralPane
    private let scope: ScopePane
    private let index: IndexPane
    private var panes: [SettingsPane] { [general, scope, index] }
    private var window: NSWindow?
    private var current: SettingsPane?
    private var poll: Timer?

    init(service: SearchService, hotKey: HotKey, onShortcutChange: @escaping () -> Void,
         onShowAccessGuide: @escaping () -> Void) {
        general = GeneralPane(hotKey: hotKey, onShortcutChange: onShortcutChange)
        scope = ScopePane(service: service, onShowAccessGuide: onShowAccessGuide)
        index = IndexPane(service: service)
        super.init()
        for pane in panes { pane.onSizeChange = { [weak self, weak pane] in if let pane { self?.fit(pane) } } }
    }

    var isVisible: Bool { window?.isVisible == true }

    func show() {
        if window == nil { build() }
        panes.forEach { $0.reload() }
        NSApp.activate(ignoringOtherApps: true)
        if window?.isVisible != true { window?.center() }
        window?.makeKeyAndOrderFront(nil)
        startPolling()
    }

    /// Brings the window back in front after the application's activation
    /// policy changed, which hides the windows of an accessory application.
    func reassert() {
        guard isVisible else { return }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func update(_ status: IndexStatus) {
        guard isVisible else { return }
        scope.update(status)
        index.update(status)
    }

    // MARK: Window

    private func build() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 200),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.toolbarStyle = .preference
        window.collectionBehavior = [.moveToActiveSpace]
        let toolbar = NSToolbar(identifier: "settings")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        self.window = window
        let saved = UserDefaults.standard.string(forKey: Self.paneKey)
        select(panes.first { $0.identifier.rawValue == saved } ?? general, animated: false)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        panes.forEach { $0.reload() }
        startPolling()
    }

    func windowWillClose(_ notification: Notification) {
        poll?.invalidate()
        poll = nil
        general.cancelRecording()
    }

    /// Permission and login-item state can change in System Settings while
    /// this window is open; a cheap check every second keeps them current.
    private func startPolling() {
        guard poll == nil else { return }
        poll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, self.isVisible else { return }
            self.general.reloadLoginItem()
            self.scope.reloadAccess()
        }
    }

    private func select(_ pane: SettingsPane, animated: Bool) {
        guard let window else { return }
        window.toolbar?.selectedItemIdentifier = pane.identifier
        window.title = pane.title
        UserDefaults.standard.set(pane.identifier.rawValue, forKey: Self.paneKey)
        guard pane !== current else { return }
        current = pane
        pane.reload()
        let view = pane.view
        window.contentView = view
        fit(pane, animated: animated)
        if animated && !Motion.reduced {
            view.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                view.animator().alphaValue = 1
            }
        }
    }

    /// Resizes the window to the pane, keeping its top edge in place.
    private func fit(_ pane: SettingsPane, animated: Bool = true) {
        guard let window, pane === current else { return }
        let size = NSSize(width: Self.width, height: pane.fittingHeight(width: Self.width))
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        guard abs(frame.height - window.frame.height) > 0.5 else { return }
        window.setFrame(frame, display: true, animate: animated && window.isVisible && !Motion.reduced)
    }

    @objc private func toolbarItemClicked(_ sender: NSToolbarItem) {
        if let pane = panes.first(where: { $0.identifier == sender.itemIdentifier }) { select(pane, animated: true) }
    }

    // MARK: Toolbar

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { panes.map(\.identifier) }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { panes.map(\.identifier) }
    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { panes.map(\.identifier) }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let pane = panes.first(where: { $0.identifier == identifier }) else { return nil }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = pane.title
        item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
        item.target = self
        item.action = #selector(toolbarItemClicked(_:))
        return item
    }
}

// MARK: - Panes

/// One tab: a two-column form, labels on the right edge of the first column.
class SettingsPane {
    let identifier: NSToolbarItem.Identifier
    let title: String
    let symbol: String
    let view = NSView()
    let grid = NSGridView()
    var onSizeChange: (() -> Void)?

    static let noteWidth: CGFloat = 300

    init(identifier: String, title: String, symbol: String) {
        self.identifier = NSToolbarItem.Identifier(identifier)
        self.title = title
        self.symbol = symbol
        grid.rowSpacing = 6
        grid.columnSpacing = 10
        grid.rowAlignment = .firstBaseline
        grid.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: view.topAnchor, constant: 24),
            grid.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            grid.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 30),
        ])
    }

    func reload() {}

    func fittingHeight(width: CGFloat) -> CGFloat {
        grid.layoutSubtreeIfNeeded()
        return ceil(grid.fittingSize.height) + 24 + 26
    }

    /// Adds a row. `label` names the group and is set only on its first row.
    @discardableResult
    func addRow(_ label: String?, _ control: NSView, gap: CGFloat = 0) -> NSGridRow {
        let title: NSView
        if let label {
            let field = NSTextField(labelWithString: label)
            field.alignment = .right
            title = field
        } else {
            title = NSGridCell.emptyContentView
        }
        let row = grid.addRow(with: [title, control])
        row.topPadding = gap
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .leading
        return row
    }

    /// Small explanatory text under a control.
    func note(_ text: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.textColor = .secondaryLabelColor
        field.preferredMaxLayoutWidth = Self.noteWidth
        field.isSelectable = false
        return field
    }

    /// A row of explanatory or warning text that is shown only when needed.
    func messageRow(after gap: CGFloat = 0) -> (NSGridRow, NSTextField) {
        let field = note("")
        field.textColor = .systemRed
        let row = addRow(nil, field, gap: gap)
        row.isHidden = true
        return (row, field)
    }

    func show(_ row: NSGridRow, _ label: NSTextField, text: String?) {
        let hidden = text == nil
        if let text { label.stringValue = text }
        guard row.isHidden != hidden else { return }
        row.isHidden = hidden
        onSizeChange?()
    }
}

// MARK: General

private final class GeneralPane: SettingsPane {
    private let hotKey: HotKey
    private let onShortcutChange: () -> Void
    private let login = NSButton(checkboxWithTitle: "登录时启动", target: nil, action: nil)
    private var loginMessageRow: NSGridRow!
    private var loginMessage: NSTextField!
    private var loginApprovalRow: NSGridRow!
    private let recorder = ShortcutRecorder(frame: .zero)
    private let restore = NSButton(title: "恢复默认", target: nil, action: nil)
    private var shortcutMessageRow: NSGridRow!
    private var shortcutMessage: NSTextField!
    private let dock = NSButton(checkboxWithTitle: "在程序坞显示图标", target: nil, action: nil)
    /// The last failure stays on screen until the next attempt.
    private var loginFailure: String?

    init(hotKey: HotKey, onShortcutChange: @escaping () -> Void) {
        self.hotKey = hotKey
        self.onShortcutChange = onShortcutChange
        super.init(identifier: "general", title: "通用", symbol: "gearshape")

        login.target = self
        login.action = #selector(toggleLogin)
        addRow("启动：", login)
        (loginMessageRow, loginMessage) = messageRow()
        let approve = NSButton(title: "打开登录项设置…", target: self, action: #selector(openLoginItems))
        approve.controlSize = .small
        approve.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let approval = NSStackView(views: [note("需要在系统设置的“登录项”里允许本应用。"), approve])
        approval.orientation = .vertical
        approval.alignment = .leading
        approval.spacing = 6
        loginApprovalRow = addRow(nil, approval)
        loginApprovalRow.isHidden = true

        recorder.onRecord = { [weak self] in self?.apply($0) }
        recorder.onRecordingChange = { [weak self] recording in
            guard let self else { return }
            if recording {
                self.hotKey.suspend()
                self.show(self.shortcutMessageRow, self.shortcutMessage, text: nil)
            } else {
                self.hotKey.resume()
            }
        }
        restore.target = self
        restore.action = #selector(restoreDefault)
        let shortcutRow = NSStackView(views: [recorder, restore])
        shortcutRow.spacing = 8
        shortcutRow.alignment = .firstBaseline
        addRow("全局快捷键：", shortcutRow, gap: 14)
        addRow(nil, note("在任何地方按下这组键都可以打开或收起搜索。点按上面的框，然后按下新的组合键；按 Esc 取消。"))
        (shortcutMessageRow, shortcutMessage) = messageRow()

        dock.target = self
        dock.action = #selector(toggleDock)
        addRow("程序坞：", dock, gap: 14)
        addRow(nil, note("关闭时只在菜单栏显示图标。"))
    }

    override func reload() {
        reloadLoginItem()
        recorder.shortcut = hotKey.shortcut ?? Shortcut.saved
        restore.isEnabled = recorder.shortcut != .standard
        dock.state = NSApp.activationPolicy() == .regular ? .on : .off
    }

    func cancelRecording() {
        if recorder.isRecording { recorder.window?.makeFirstResponder(nil) }
    }

    // MARK: Login item

    /// The switch always shows what the system has actually registered.
    func reloadLoginItem() {
        let status = SMAppService.mainApp.status
        login.state = status == .enabled || status == .requiresApproval ? .on : .off
        let needsApproval = status == .requiresApproval
        if loginApprovalRow.isHidden == needsApproval {
            loginApprovalRow.isHidden = !needsApproval
            onSizeChange?()
        }
        show(loginMessageRow, loginMessage, text: loginFailure)
    }

    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        let wanted = login.state == .on
        do {
            if wanted { try service.register() } else { try service.unregister() }
            loginFailure = nil
        } catch {
            let action = wanted ? "无法设为登录时启动" : "无法取消登录时启动"
            loginFailure = "\(action)：\(error.localizedDescription)"
        }
        reloadLoginItem()
    }

    @objc private func openLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }

    // MARK: Shortcut

    private func apply(_ shortcut: Shortcut) {
        switch hotKey.register(shortcut) {
        case .success:
            shortcut.save()
            show(shortcutMessageRow, shortcutMessage, text: nil)
        case .failure(let failure):
            hotKey.resume()
            show(shortcutMessageRow, shortcutMessage, text: "\(shortcut.display)：\(failure.message)")
        }
        reload()
        onShortcutChange()
    }

    @objc private func restoreDefault() {
        cancelRecording()
        apply(.standard)
    }

    // MARK: Dock

    @objc private func toggleDock() {
        let visible = dock.state == .on
        Preferences.showDockIcon = visible
        NSApp.setActivationPolicy(visible ? .regular : .accessory)
        // An accessory application loses its active state; keep this window in front.
        DispatchQueue.main.async { [weak self] in
            (NSApp.delegate as? AppDelegate)?.settingsDidChangeDockIcon()
            self?.reload()
        }
    }
}

// MARK: Search scope

private final class ScopePane: SettingsPane {
    private let service: SearchService
    private let onShowAccessGuide: () -> Void
    private let systemFiles = NSButton(checkboxWithTitle: "显示系统文件和隐藏文件", target: nil, action: nil)
    private let accessIcon = NSImageView()
    private let accessLabel = NSTextField(labelWithString: "")
    private let accessButton = NSButton(title: "前往授权…", target: nil, action: nil)
    private let places = NSStackView()
    private let placesList = PlacesList()
    private let placesEmpty = NSTextField(labelWithString: "没有无法访问的位置")
    private let placesCount = NSTextField(labelWithString: "")
    private var shownPaths: [String]?

    init(service: SearchService, onShowAccessGuide: @escaping () -> Void) {
        self.service = service
        self.onShowAccessGuide = onShowAccessGuide
        super.init(identifier: "scope", title: "搜索范围", symbol: "magnifyingglass")

        systemFiles.target = self
        systemFiles.action = #selector(toggleSystemFiles)
        addRow("显示：", systemFiles)
        addRow(nil, note("包括系统目录、个人“资源库”、应用程序包内部，以及名称以“.”开头的文件。"))

        accessIcon.symbolConfiguration = .init(pointSize: 13, weight: .regular)
        accessButton.target = self
        accessButton.action = #selector(showGuide)
        accessButton.controlSize = .small
        accessButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let access = NSStackView(views: [accessIcon, accessLabel, accessButton])
        access.spacing = 5
        access.alignment = .firstBaseline
        access.setCustomSpacing(10, after: accessLabel)
        addRow("完整磁盘访问：", access, gap: 14)
        addRow(nil, note("未授权时，邮件、信息等受系统保护的位置搜不到。"))

        places.orientation = .vertical
        places.alignment = .leading
        places.spacing = 6
        placesCount.textColor = .secondaryLabelColor
        places.setViews([placesEmpty, placesCount, placesList,
                         note("这些位置里的文件不会出现在结果中。授予完整磁盘访问权限后，大多可以恢复。")], in: .top)
        addRow("无法访问的位置：", places, gap: 14).yPlacement = .top
    }

    override func reload() {
        systemFiles.state = Preferences.includeSystemFiles ? .on : .off
        reloadAccess()
        update(service.status)
    }

    func reloadAccess() {
        let granted = DiskAccess.isGranted
        accessLabel.stringValue = granted ? "已授权" : "未授权"
        accessIcon.image = NSImage(systemSymbolName: granted ? "checkmark.circle.fill" : "circle.dashed",
                                   accessibilityDescription: nil)
        accessIcon.contentTintColor = granted ? .systemGreen : .tertiaryLabelColor
        accessButton.isHidden = granted
    }

    func update(_ status: IndexStatus) {
        let paths = status.inaccessiblePaths
        guard paths != shownPaths else { return }
        shownPaths = paths
        placesEmpty.isHidden = !paths.isEmpty
        for view in places.arrangedSubviews where view !== placesEmpty { view.isHidden = paths.isEmpty }
        placesCount.stringValue = "共 \(NumberFormatter.localizedString(from: NSNumber(value: paths.count), number: .decimal)) 个位置"
        placesList.paths = paths
        onSizeChange?()
    }

    @objc private func toggleSystemFiles() {
        Preferences.includeSystemFiles = systemFiles.state == .on
    }

    @objc private func showGuide() { onShowAccessGuide() }
}

// MARK: Index

private final class IndexPane: SettingsPane {
    private let service: SearchService
    private let state = NSTextField(labelWithString: "")
    private let count = NSTextField(labelWithString: "")
    private let size = NSTextField(labelWithString: "")
    private let rebuild = NSButton(title: "立即重建索引…", target: nil, action: nil)

    init(service: SearchService) {
        self.service = service
        super.init(identifier: "index", title: "索引", symbol: "internaldrive")
        for field in [count, size] { field.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular) }
        addRow("状态：", state)
        addRow("已收录文件：", count)
        addRow("占用空间：", size)
        rebuild.target = self
        rebuild.action = #selector(confirmRebuild)
        addRow(nil, rebuild, gap: 14)
        addRow(nil, note("从头核对整台电脑的文件。结果明显不全或不准时使用；期间仍可以搜索。"))
    }

    override func reload() { update(service.status) }

    func update(_ status: IndexStatus) {
        state.stringValue = status.summary
        count.stringValue = NumberFormatter.localizedString(from: NSNumber(value: status.indexedCount),
                                                            number: .decimal) + " 个"
        size.stringValue = ByteCountFormatter.string(fromByteCount: status.indexBytesOnDisk, countStyle: .file)
        rebuild.isEnabled = !status.isBusy
    }

    @objc private func confirmRebuild() {
        let alert = NSAlert()
        alert.messageText = "要重建索引吗？"
        alert.informativeText = "重建通常需要一到几分钟，期间仍可以搜索，完成后结果会完整准确。"
        alert.addButton(withTitle: "重建")
        alert.addButton(withTitle: "取消")
        // A free-standing alert: this pane is shorter than an alert sheet,
        // which would be cut off at the bottom of the window.
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        rebuild.isEnabled = false
        service.rebuild()
    }
}

/// A short bordered list of folders, scrolling when there are many.
private final class PlacesList: NSScrollView, NSTableViewDataSource, NSTableViewDelegate {
    var paths: [String] = [] { didSet { table.reloadData() } }
    private let table = NSTableView()

    init() {
        super.init(frame: .zero)
        let column = NSTableColumn(identifier: .init("path"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 20
        table.style = .plain
        table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel("无法访问的位置")
        documentView = table
        borderType = .bezelBorder
        hasVerticalScroller = true
        autohidesScrollers = true
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: SettingsPane.noteWidth + 40),
            heightAnchor.constraint(equalToConstant: 20 * 6 + 2),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func numberOfRows(in tableView: NSTableView) -> Int { paths.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("place")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView ?? {
            let cell = NSTableCellView()
            cell.identifier = identifier
            let icon = NSImageView(image: NSImage(systemSymbolName: "folder", accessibilityDescription: nil) ?? NSImage())
            icon.contentTintColor = .secondaryLabelColor
            icon.symbolConfiguration = .init(pointSize: 11, weight: .regular)
            let label = NSTextField(labelWithString: "")
            label.lineBreakMode = .byTruncatingMiddle
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            for view in [icon, label] {
                view.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(view)
            }
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 16),
                label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 4),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            cell.textField = label
            return cell
        }()
        let path = paths[row]
        cell.textField?.stringValue = (path as NSString).abbreviatingWithTildeInPath
        cell.toolTip = path
        return cell
    }
}
