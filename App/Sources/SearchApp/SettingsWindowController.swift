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

    init(service: SearchService, shortcuts: ShortcutCenter, onShowAccessGuide: @escaping () -> Void) {
        general = GeneralPane(shortcuts: shortcuts)
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

    /// `warning` text is red; otherwise it is an ordinary explanation.
    func show(_ row: NSGridRow, _ label: NSTextField, text: String?, warning: Bool = true) {
        let hidden = text == nil
        if let text { label.stringValue = text }
        label.textColor = warning ? .systemRed : .secondaryLabelColor
        guard row.isHidden != hidden else { return }
        row.isHidden = hidden
        onSizeChange?()
    }
}

// MARK: General

private final class GeneralPane: SettingsPane {
    /// The controls of one shortcut row.
    private final class ShortcutRow {
        let role: ShortcutRole
        let recorder: ShortcutRecorder
        let restore = NSButton(title: "恢复默认", target: nil, action: nil)
        var messageRow: NSGridRow!
        var message: NSTextField!
        /// The last refusal stays on screen until the next attempt.
        var failure: String?

        init(role: ShortcutRole) {
            self.role = role
            recorder = ShortcutRecorder(name: role.title, shortcut: role.standard)
            restore.setAccessibilityLabel("将\(role.title)恢复默认")
        }
    }

    private let shortcuts: ShortcutCenter
    private let login = NSButton(checkboxWithTitle: "登录时启动", target: nil, action: nil)
    private var loginMessageRow: NSGridRow!
    private var loginMessage: NSTextField!
    private var loginApprovalRow: NSGridRow!
    private let shortcutRows = ShortcutRole.allCases.map(ShortcutRow.init)
    private let dock = NSButton(checkboxWithTitle: "在程序坞显示图标", target: nil, action: nil)
    /// The last failure stays on screen until the next attempt.
    private var loginFailure: String?

    init(shortcuts: ShortcutCenter) {
        self.shortcuts = shortcuts
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

        for (index, row) in shortcutRows.enumerated() {
            row.recorder.onRecord = { [weak self, weak row] in
                if let row { self?.apply($0, to: row) }
            }
            row.recorder.onRecordingChange = { [weak self, weak row] recording in
                guard let self, let row else { return }
                if recording {
                    // Pressing the current global shortcut must reach the
                    // recorder, to be recorded or refused like any other.
                    self.shortcuts.suspendGlobal()
                    row.failure = nil
                    self.show(row.messageRow, row.message, text: nil)
                } else {
                    self.shortcuts.resumeGlobal()
                }
            }
            row.restore.tag = index
            row.restore.target = self
            row.restore.action = #selector(restoreDefault(_:))
            let controls = NSStackView(views: [row.recorder, row.restore])
            controls.spacing = 8
            controls.alignment = .firstBaseline
            addRow("\(row.role.title)：", controls, gap: index == 0 ? 14 : 10)
            addRow(nil, note(Self.explanation(row.role)))
            (row.messageRow, row.message) = messageRow()
        }
        addRow(nil, note("""
            点按框后按下新的组合键，按 Esc 取消。组合需包含 ⌃、⌥、⌘ 中的至少一个（F1 至 F12 可以单独使用）；\
            两个快捷键不能相同，也不能与面板里的固定按键、文本编辑的标准按键或系统已启用的快捷键相同。\
            其他应用占用的组合无法事先查出：全局快捷键要在登记失败时才知道，有的应用直接截取按键，这种冲突本软件发现不了。
            """), gap: 4)

        dock.target = self
        dock.action = #selector(toggleDock)
        addRow("程序坞：", dock, gap: 14)
        addRow(nil, note("关闭时只在菜单栏显示图标。"))
    }

    private static func explanation(_ role: ShortcutRole) -> String {
        switch role {
        case .global: return "在任何地方按下都可以打开或收起搜索。"
        case .preview: return "在搜索面板里按下，用快速查看预览选中的文件。⌘Y 也始终可以预览，不能更改。"
        }
    }

    override func reload() {
        reloadLoginItem()
        for row in shortcutRows {
            row.recorder.shortcut = shortcuts.current(row.role)
            row.restore.isEnabled = row.recorder.shortcut != row.role.standard
            if let failure = row.failure {
                show(row.messageRow, row.message, text: failure)
            } else if let notice = shortcuts.notices[row.role] {
                show(row.messageRow, row.message, text: notice, warning: false)
            } else if row.role == .preview, shortcuts.isTakenBySystem(.preview) {
                // System shortcuts can change while this application runs.
                show(row.messageRow, row.message,
                     text: "\(row.recorder.shortcut.display) 现已被系统快捷键占用，在面板里按下不会生效，请换一组。")
            } else if row.role == .global, shortcuts.registeredGlobal == nil {
                show(row.messageRow, row.message,
                     text: "\(row.recorder.shortcut.display) 已被其他应用占用，全局快捷键目前不可用，请换一组。")
            } else {
                show(row.messageRow, row.message, text: nil)
            }
        }
        dock.state = NSApp.activationPolicy() == .regular ? .on : .off
    }

    func cancelRecording() {
        for row in shortcutRows where row.recorder.isRecording { row.recorder.window?.makeFirstResponder(nil) }
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

    private func apply(_ shortcut: Shortcut, to row: ShortcutRow) {
        if let problem = shortcuts.change(row.role, to: shortcut) {
            shortcuts.resumeGlobal()
            row.failure = problem.refusal(for: shortcut)
        } else {
            row.failure = nil
        }
        reload()
    }

    @objc private func restoreDefault(_ sender: NSButton) {
        guard shortcutRows.indices.contains(sender.tag) else { return }
        cancelRecording()
        let row = shortcutRows[sender.tag]
        apply(row.role.standard, to: row)
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
    private let placesCount = NSTextField(labelWithString: "")
    private let placesOutline = InaccessibleOutline()
    private var placesNote: NSTextField!
    private var pendingRow: NSGridRow!
    private let pendingList = PlacesList()
    private var shown: (raw: [InaccessiblePlace], merged: [InaccessiblePlace])?
    private var pendingPaths: [String] = []

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

        placesNote = note("搜索范围是整台电脑。上面列出的位置读不到，其中的文件不会出现在搜索结果中。点按三角形可以查看每一项包含的具体位置。")
        let places = NSStackView(views: [placesCount, placesOutline, placesNote])
        places.orientation = .vertical
        places.alignment = .leading
        places.spacing = 6
        addRow("无法访问的位置：", places, gap: 14)

        let pending = NSStackView(views: [
            note("为了不触发系统的权限弹窗，未授权时软件不会读取其他应用的数据文件夹；授权后自动补上。"),
            pendingList,
        ])
        pending.orientation = .vertical
        pending.alignment = .leading
        pending.spacing = 6
        pendingRow = addRow("等待授权的位置：", pending, gap: 14)
        pendingRow.isHidden = true
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
        showPending()
    }

    func update(_ status: IndexStatus) {
        if status.pendingFullDiskAccessPaths != pendingPaths {
            pendingPaths = status.pendingFullDiskAccessPaths
            pendingList.paths = pendingPaths
            showPending()
        }
        guard shown?.raw != status.rawInaccessiblePlaces || shown?.merged != status.inaccessiblePlaces else { return }
        let wasEmpty = shown.map { $0.raw.isEmpty && $0.merged.isEmpty } ?? true
        shown = (status.rawInaccessiblePlaces, status.inaccessiblePlaces)
        let total = status.inaccessibleCount
        placesCount.stringValue = total == 0 ? "没有无法访问的位置" : "共 \(formatted(total)) 个位置读不到"
        placesOutline.show(raw: status.rawInaccessiblePlaces, merged: status.inaccessiblePlaces)
        let isEmpty = status.rawInaccessiblePlaces.isEmpty && status.inaccessiblePlaces.isEmpty
        placesOutline.isHidden = isEmpty
        placesNote.isHidden = isEmpty
        if isEmpty != wasEmpty { onSizeChange?() }
    }

    /// The pending folders matter only until access is granted.
    private func showPending() {
        let hidden = pendingPaths.isEmpty || DiskAccess.isGranted
        guard pendingRow.isHidden != hidden else { return }
        pendingRow.isHidden = hidden
        onSizeChange?()
    }

    @objc private func toggleSystemFiles() {
        Preferences.includeSystemFiles = systemFiles.state == .on
    }

    @objc private func showGuide() { onShowAccessGuide() }
}

private func formatted(_ number: Int) -> String {
    NumberFormatter.localizedString(from: NSNumber(value: number), number: .decimal)
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

/// A short bordered list of folders, as tall as its rows up to a limit and
/// scrolling beyond it.
private final class PlacesList: NSScrollView, NSTableViewDataSource, NSTableViewDelegate {
    private static let rowHeight: CGFloat = 20
    private static let maxRows = 5
    var paths: [String] = [] {
        didSet {
            height.constant = Self.rowHeight * CGFloat(min(max(paths.count, 1), Self.maxRows)) + 2
            table.reloadData()
        }
    }
    private let table = NSTableView()
    private var height: NSLayoutConstraint!

    init() {
        super.init(frame: .zero)
        let column = NSTableColumn(identifier: .init("path"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = Self.rowHeight
        table.style = .plain
        table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel("等待授权的位置")
        documentView = table
        borderType = .bezelBorder
        hasVerticalScroller = true
        autohidesScrollers = true
        translatesAutoresizingMaskIntoConstraints = false
        height = heightAnchor.constraint(equalToConstant: Self.rowHeight + 2)
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: InaccessibleOutline.width), height])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func numberOfRows(in tableView: NSTableView) -> Int { paths.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = PlaceCell.make(in: tableView, kind: .place)
        cell.show(path: paths[row], title: (paths[row] as NSString).abbreviatingWithTildeInPath, count: nil)
        return cell
    }
}

/// One line in the access lists: an optional folder symbol, the path cut in
/// the middle when long, and an optional count that always stays visible.
private final class PlaceCell: NSTableCellView {
    enum Kind: String { case place, detail }

    private let countLabel = NSTextField(labelWithString: "")

    static func make(in tableView: NSTableView, kind: Kind) -> PlaceCell {
        let identifier = NSUserInterfaceItemIdentifier("place-" + kind.rawValue)
        if let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? PlaceCell { return cell }
        let cell = PlaceCell(kind: kind)
        cell.identifier = identifier
        return cell
    }

    private init(kind: Kind) {
        super.init(frame: .zero)
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingMiddle
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = kind == .place ? .labelColor : .secondaryLabelColor
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        countLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        countLabel.textColor = .secondaryLabelColor
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        countLabel.setContentHuggingPriority(.required, for: .horizontal)
        var views: [NSView] = [label, countLabel]
        if kind == .place {
            let icon = NSImageView(image: NSImage(systemSymbolName: "folder", accessibilityDescription: nil) ?? NSImage())
            icon.contentTintColor = .secondaryLabelColor
            icon.symbolConfiguration = .init(pointSize: 11, weight: .regular)
            icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
            views.insert(icon, at: 0)
        }
        let row = NSStackView(views: views)
        row.spacing = 4
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        textField = label
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(path: String, title: String, count: Int?) {
        textField?.stringValue = title
        countLabel.stringValue = count.map { "（含 \(formatted($0)) 个位置）" } ?? ""
        countLabel.isHidden = count == nil
        toolTip = path
    }
}

/// The unreadable locations grouped by reason. Each group lists the merged
/// entries, and each merged entry opens onto the locations it stands for.
private final class InaccessibleOutline: NSScrollView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    static let width: CGFloat = 360
    private static let rowHeight: CGFloat = 20

    final class Node: NSObject {
        enum Kind {
            case group(AccessReason, count: Int)
            case place(InaccessiblePlace)
            case detail(InaccessiblePlace, parent: String)
        }
        let key: String
        let kind: Kind
        var children: [Node] = []

        init(key: String, kind: Kind) {
            self.key = key
            self.kind = kind
        }

        override func isEqual(_ object: Any?) -> Bool { (object as? Node)?.key == key }
        override var hash: Int { key.hashValue }
    }

    private let outline = NSOutlineView()
    private var groups: [Node] = []
    /// The width a group heading's cell actually got, reported back by the
    /// cell once laid out. Until then it is estimated from the list width.
    private var groupCellWidth: CGFloat?

    init() {
        super.init(frame: .zero)
        let column = NSTableColumn(identifier: .init("place"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .plain
        outline.rowHeight = Self.rowHeight
        outline.indentationPerLevel = 14
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.dataSource = self
        outline.delegate = self
        outline.setAccessibilityLabel("无法访问的位置")
        documentView = outline
        borderType = .bezelBorder
        hasVerticalScroller = true
        autohidesScrollers = true
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.width),
            heightAnchor.constraint(equalToConstant: 260),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Keeps the single column exactly as wide as the visible area, so long
    /// paths are cut in the middle and the explanations wrap inside it.
    override func tile() {
        super.tile()
        let before = outline.tableColumns.first?.width
        outline.sizeLastColumnToFit()
        if outline.tableColumns.first?.width != before {
            outline.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<outline.numberOfRows))
        }
    }

    /// Replaces the contents, keeping what was open, what was selected and
    /// where the list was scrolled to.
    func show(raw: [InaccessiblePlace], merged: [InaccessiblePlace]) {
        let previous = Set(groups.map(\.key))
        var expanded = Set<String>()
        func collect(_ nodes: [Node]) {
            for node in nodes where outline.isItemExpanded(node) {
                expanded.insert(node.key)
                collect(node.children)
            }
        }
        collect(groups)
        let selected = (outline.item(atRow: outline.selectedRow) as? Node)?.key
        let origin = contentView.bounds.origin

        groups = Self.tree(raw: raw, merged: merged)
        outline.reloadData()
        func restore(_ nodes: [Node]) {
            for node in nodes {
                let isGroup = if case .group = node.kind { true } else { false }
                // A group seen for the first time starts open.
                if expanded.contains(node.key) || (isGroup && !previous.contains(node.key)) {
                    outline.expandItem(node)
                    restore(node.children)
                }
            }
        }
        restore(groups)
        if let selected, let node = find(selected, in: groups) {
            let row = outline.row(forItem: node)
            if row >= 0 { outline.selectRowIndexes([row], byExtendingSelection: false) }
        } else {
            outline.deselectAll(nil)
        }
        outline.layoutSubtreeIfNeeded()
        let limit = max(0, outline.frame.height - contentView.bounds.height)
        contentView.scroll(to: NSPoint(x: 0, y: min(origin.y, limit)))
        reflectScrolledClipView(contentView)
    }

    private func find(_ key: String, in nodes: [Node]) -> Node? {
        for node in nodes {
            if node.key == key { return node }
            if let found = find(key, in: node.children) { return found }
        }
        return nil
    }

    /// Groups the merged entries by reason and files every raw location under
    /// the merged entry that covers it. A raw location no entry covers is
    /// still listed, as an entry of its own.
    private static func tree(raw: [InaccessiblePlace], merged: [InaccessiblePlace]) -> [Node] {
        AccessReason.allCases.compactMap { reason in
            let entries = merged.filter { $0.reason == reason }
            var details: [String: [InaccessiblePlace]] = [:]
            var loose: [InaccessiblePlace] = []
            let covering = Set(entries.map(\.path))
            for place in raw where place.reason == reason {
                var path = place.path
                while !covering.contains(path), path != "/", !path.isEmpty {
                    path = (path as NSString).deletingLastPathComponent
                }
                if covering.contains(path) { details[path, default: []].append(place) } else { loose.append(place) }
            }
            let places = (entries + loose).sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            guard !places.isEmpty else { return nil }
            let groupKey = "\(reason)"
            let group = Node(key: groupKey, kind: .group(reason, count: places.reduce(0) { $0 + $1.count }))
            group.children = places.map { place in
                let node = Node(key: groupKey + "\u{0}" + place.path, kind: .place(place))
                let inside = details[place.path] ?? []
                // A single location that is the entry itself needs no detail.
                if !(inside.count == 1 && inside[0].path == place.path) {
                    node.children = inside.map {
                        Node(key: node.key + "\u{0}" + $0.path, kind: .detail($0, parent: place.path))
                    }
                }
                return node
            }
            return group
        }
    }

    private static func title(_ reason: AccessReason) -> String {
        switch reason {
        case .needsFullDiskAccess: "授权后可读"
        case .filePermissions: "系统权限限制"
        case .unknown: "原因不明"
        }
    }

    private static func explanation(_ reason: AccessReason) -> String {
        switch reason {
        case .needsFullDiskAccess: "授予完整磁盘访问权限后就能读到。"
        case .filePermissions: "这些位置只有系统或其他用户能读，授权后也读不到；这是 macOS 的保护，不是软件故障。"
        case .unknown: "暂时无法判断原因。"
        }
    }

    // MARK: Data

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? Node)?.children.count ?? groups.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? Node)?.children[index] ?? groups[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !((item as? Node)?.children.isEmpty ?? true)
    }

    // MARK: Appearance

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        guard let node = item as? Node, case .group(let reason, _) = node.kind else { return Self.rowHeight }
        let probe = GroupCell.measuring
        probe.show(reason: reason, title: "", explanation: Self.explanation(reason))
        // The column can still be at its initial width when rows are first
        // measured; a heading is indented by the disclosure triangle.
        let estimate = max(outline.tableColumns.first?.width ?? 0, Self.width - 4) - 26
        return probe.height(forWidth: max(groupCellWidth ?? estimate, 120))
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? Node else { return nil }
        switch node.kind {
        case .group(let reason, let count):
            let identifier = NSUserInterfaceItemIdentifier("group")
            let cell = outlineView.makeView(withIdentifier: identifier, owner: nil) as? GroupCell ?? {
                let cell = GroupCell()
                cell.identifier = identifier
                return cell
            }()
            cell.show(reason: reason, title: "\(Self.title(reason)) · \(formatted(count)) 个位置",
                      explanation: Self.explanation(reason))
            cell.onWidthChange = { [weak self] width in self?.noteGroupCellWidth(width) }
            return cell
        case .place(let place):
            let cell = PlaceCell.make(in: outlineView, kind: .place)
            cell.show(path: place.path, title: (place.path as NSString).abbreviatingWithTildeInPath,
                      count: place.count > 1 ? place.count : nil)
            return cell
        case .detail(let place, let parent):
            let cell = PlaceCell.make(in: outlineView, kind: .detail)
            let title: String
            if place.path == parent {
                title = "此位置本身"
            } else if parent == "/" {
                title = String(place.path.dropFirst())
            } else {
                title = String(place.path.dropFirst(parent.count + 1))
            }
            cell.show(path: place.path, title: title, count: nil)
            return cell
        }
    }

    /// Re-measures the headings when their cells turn out wider or narrower
    /// than the width their height was worked out for.
    private func noteGroupCellWidth(_ width: CGFloat) {
        guard width > 0, abs((groupCellWidth ?? -1) - width) > 0.5 else { return }
        groupCellWidth = width
        let rows = groups.map { outline.row(forItem: $0) }.filter { $0 >= 0 }
        guard !rows.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            self?.outline.noteHeightOfRows(withIndexesChanged: IndexSet(rows))
        }
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        if let node = item as? Node, case .group = node.kind { return false }
        return true
    }
}

/// A group heading: a symbol, the bold name with its count, and one line of
/// explanation under it.
private final class GroupCell: NSTableCellView {
    static let measuring = GroupCell()

    private let icon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let explanationLabel = NSTextField(wrappingLabelWithString: "")
    /// Told the cell's laid-out width, so the list can size the row to it.
    var onWidthChange: ((CGFloat) -> Void)?

    init() {
        super.init(frame: .zero)
        icon.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
        icon.setContentHuggingPriority(.required, for: .horizontal)
        titleLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        explanationLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        explanationLabel.textColor = .secondaryLabelColor
        explanationLabel.isSelectable = false
        let heading = NSStackView(views: [icon, titleLabel])
        heading.spacing = 4
        let stack = NSStackView(views: [heading, explanationLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
        ])
        textField = titleLabel
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(reason: AccessReason, title: String, explanation: String) {
        let symbol: String
        let tint: NSColor
        switch reason {
        case .needsFullDiskAccess: (symbol, tint) = ("key", .systemBlue)
        case .filePermissions: (symbol, tint) = ("lock", .secondaryLabelColor)
        case .unknown: (symbol, tint) = ("questionmark.circle", .secondaryLabelColor)
        }
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.contentTintColor = tint
        titleLabel.stringValue = title
        explanationLabel.stringValue = explanation
        setAccessibilityLabel("\(title)。\(explanation)")
    }

    override func layout() {
        explanationLabel.preferredMaxLayoutWidth = max(bounds.width - 6, 0)
        super.layout()
        onWidthChange?(bounds.width)
    }

    /// The row height that shows the whole explanation at this cell width:
    /// top inset, heading, spacing, explanation, and a bottom inset that
    /// leaves the same gap before the first location as between locations.
    func height(forWidth width: CGFloat) -> CGFloat {
        explanationLabel.preferredMaxLayoutWidth = width - 6
        let text = explanationLabel.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width - 6, height: 1000))
        let lineHeight = ceil(NSFont.systemFont(ofSize: NSFont.smallSystemFontSize).boundingRectForFont.height)
        let heading = max(ceil(titleLabel.intrinsicContentSize.height), lineHeight)
        return 6 + heading + 2 + ceil(text?.height ?? lineHeight) + 3
    }
}
