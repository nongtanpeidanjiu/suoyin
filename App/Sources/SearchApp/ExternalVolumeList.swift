import AppKit

/// A bordered list of attached volumes, each with a switch that adds it to
/// the search, in the settings window and in the setup guide. It is as tall
/// as its rows up to `maxRows` and scrolls beyond that. Updates change the
/// rows in place, so rising counts neither flicker nor move the list.
final class ExternalVolumeList: NSScrollView, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    static let rowHeight: CGFloat = 40

    /// Called with a volume's id and whether it should be searched.
    var onToggle: ((String, Bool) -> Void)?
    /// Called with a volume whose indexed data the user asked to delete;
    /// nil hides the menu.
    var onDelete: ((ExternalVolume) -> Void)?
    /// Called after the list changed height.
    var onHeightChange: (() -> Void)?

    private(set) var volumes: [ExternalVolume] = []
    private let table = NSTableView()
    private let placeholder = NSTextField(labelWithString: "")
    private let maxRows: Int
    private var height: NSLayoutConstraint!

    init(width: CGFloat, maxRows: Int, emptyText: String) {
        self.maxRows = maxRows
        super.init(frame: .zero)
        let column = NSTableColumn(identifier: .init("volume"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = Self.rowHeight
        table.style = .plain
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.selectionHighlightStyle = .none
        table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel("外接磁盘")
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu
        documentView = table
        borderType = .bezelBorder
        hasVerticalScroller = true
        autohidesScrollers = true
        translatesAutoresizingMaskIntoConstraints = false

        placeholder.stringValue = emptyText
        placeholder.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        placeholder.textColor = .tertiaryLabelColor
        placeholder.alignment = .center
        addSubview(placeholder)

        height = heightAnchor.constraint(equalToConstant: Self.rowHeight + 2)
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: width), height])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func tile() {
        super.tile()
        if subviews.last !== placeholder { addSubview(placeholder, positioned: .above, relativeTo: nil) }
        let line = ceil(placeholder.intrinsicContentSize.height)
        placeholder.frame = NSRect(x: 0, y: ((bounds.height - line) / 2).rounded(), width: bounds.width, height: line)
        table.sizeLastColumnToFit()
    }

    /// Shows `list`. The same volumes in the same order only refresh the
    /// visible rows; otherwise the rows are rebuilt and the scroll position
    /// is kept.
    func show(_ list: [ExternalVolume]) {
        guard list != volumes else { return }
        let sameRows = list.map(\.id) == volumes.map(\.id)
        volumes = list
        placeholder.isHidden = !list.isEmpty
        if sameRows {
            for row in 0..<list.count {
                (table.view(atColumn: 0, row: row, makeIfNecessary: false) as? VolumeCell)?.show(list[row], owner: self)
            }
            return
        }
        let origin = contentView.bounds.origin
        table.reloadData()
        table.layoutSubtreeIfNeeded()
        let visible = CGFloat(min(max(list.count, 1), maxRows))
        let wanted = Self.rowHeight * visible + 2
        if abs(height.constant - wanted) > 0.5 {
            height.constant = wanted
            onHeightChange?()
        }
        let limit = max(0, table.frame.height - contentView.bounds.height)
        contentView.scroll(to: NSPoint(x: 0, y: min(origin.y, limit)))
        reflectScrolledClipView(contentView)
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { volumes.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("volume")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? VolumeCell ?? {
            let cell = VolumeCell()
            cell.identifier = identifier
            return cell
        }()
        cell.show(volumes[row], owner: self)
        return cell
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    // MARK: Menu

    fileprivate func toggle(_ id: String, _ included: Bool) { onToggle?(id, included) }

    fileprivate func menu(for volume: ExternalVolume) -> NSMenu {
        let menu = NSMenu()
        fill(menu, for: volume)
        return menu
    }

    private func fill(_ menu: NSMenu, for volume: ExternalVolume) {
        menu.removeAllItems()
        menu.autoenablesItems = false
        let item = NSMenuItem(title: "删除已收录的数据…", action: #selector(deleteChosen(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = volume.id
        // Greyed out rather than hidden, so the menu looks the same on every
        // row: there is nothing to delete, or it has not been counted yet.
        item.isEnabled = volume.hasRetainedData
        if !item.isEnabled {
            item.toolTip = volume.retainedCount == nil ? "正在统计已收录的条目，稍后再试" : "这块磁盘没有已收录的数据"
        }
        menu.addItem(item)
    }

    /// The right-click menu of the row under the pointer.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = table.clickedRow
        guard showsMenu, volumes.indices.contains(row) else { return }
        fill(menu, for: volumes[row])
    }

    @objc private func deleteChosen(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let volume = volumes.first(where: { $0.id == id }) else { return }
        onDelete?(volume)
    }

    /// The “…” button shows only where its one item can be used at all.
    var showsMenu: Bool { onDelete != nil }
}

/// One volume: symbol, name with its detail, state line, switch and an
/// optional “…” menu.
private final class VolumeCell: NSTableCellView {
    private let icon = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let stateLabel = NSTextField(labelWithString: "")
    private let toggle = NSSwitch()
    private let more = NSButton()
    private var volume: ExternalVolume?
    private weak var owner: ExternalVolumeList?

    init() {
        super.init(frame: .zero)
        icon.symbolConfiguration = .init(pointSize: 17, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor
        icon.setContentHuggingPriority(.required, for: .horizontal)
        nameLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
        // Equal-width digits: a rising count does not make the line shift.
        stateLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        stateLabel.textColor = .secondaryLabelColor
        stateLabel.lineBreakMode = .byTruncatingTail
        stateLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        toggle.controlSize = .small
        toggle.target = self
        toggle.action = #selector(switched)
        toggle.toolTip = "加入搜索"
        more.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "更多")
        more.bezelStyle = .inline
        more.isBordered = false
        more.imagePosition = .imageOnly
        more.symbolConfiguration = .init(pointSize: 14, weight: .regular)
        more.contentTintColor = .secondaryLabelColor
        more.target = self
        more.action = #selector(showMenu)
        more.toolTip = "删除已收录的数据…"

        let title = NSStackView(views: [nameLabel, detailLabel])
        title.spacing = 6
        title.alignment = .firstBaseline
        let text = NSStackView(views: [title, stateLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // The text takes the room left; the switch and menu keep their size.
        text.setHuggingPriority(.init(1), for: .horizontal)
        nameLabel.setContentCompressionResistancePriority(.init(740), for: .horizontal)
        detailLabel.setContentCompressionResistancePriority(.init(730), for: .horizontal)
        toggle.setContentHuggingPriority(.required, for: .horizontal)
        more.setContentHuggingPriority(.required, for: .horizontal)
        let row = NSStackView(views: [icon, text, toggle, more])
        row.distribution = .fill
        row.spacing = 8
        row.alignment = .centerY
        row.setCustomSpacing(10, after: icon)
        row.setCustomSpacing(6, after: toggle)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 22),
        ])
        textField = nameLabel
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ volume: ExternalVolume, owner: ExternalVolumeList) {
        self.volume = volume
        self.owner = owner
        icon.image = NSImage(systemSymbolName: "externaldrive", accessibilityDescription: nil)
        icon.alphaValue = volume.isOnline ? 1 : 0.45
        nameLabel.stringValue = volume.title
        nameLabel.textColor = volume.isOnline ? .labelColor : .secondaryLabelColor
        detailLabel.stringValue = volume.detail ?? ""
        detailLabel.isHidden = volume.detail == nil
        if stateLabel.stringValue != volume.stateLine { stateLabel.stringValue = volume.stateLine }
        let state: NSControl.StateValue = volume.isIncluded ? .on : .off
        if toggle.state != state { toggle.state = state }
        toggle.setAccessibilityLabel("将“\(volume.title)”加入搜索")
        more.isHidden = !owner.showsMenu
        more.setAccessibilityLabel("“\(volume.title)”的更多操作")
        setAccessibilityLabel("\(volume.title)，\(volume.stateLine)")
        toolTip = volume.title
    }

    @objc private func switched() {
        guard let volume else { return }
        owner?.toggle(volume.id, toggle.state == .on)
    }

    @objc private func showMenu() {
        guard let volume, let owner else { return }
        owner.menu(for: volume).popUp(positioning: nil, at: NSPoint(x: 0, y: more.bounds.maxY + 4), in: more)
    }
}

enum ExternalVolumeConfirmation {
    /// Asks before deleting what was indexed for `volume`; calls `confirmed`
    /// only after the user agreed.
    static func askToDelete(_ volume: ExternalVolume, in window: NSWindow?, confirmed: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = "要删除“\(volume.title)”已收录的数据吗？"
        var text = "将删除本软件为这块磁盘保存的"
        text += volume.retainedCount.map { " \(formattedCount($0)) 个已收录条目" } ?? "已收录条目"
        text += "，磁盘上的文件不受任何影响。"
        if volume.isOnline {
            text += "删除后不再搜索这块磁盘，它仍留在列表中，显示为“未加入”；以后可以重新加入，届时需要从头扫描。"
        } else {
            text += "这块磁盘目前未连接，删除后会从列表中移除；以后再插入时会作为新磁盘出现，加入搜索需要从头扫描。"
        }
        alert.informativeText = text
        let delete = alert.addButton(withTitle: "删除")
        delete.hasDestructiveAction = true
        // Return cancels; deleting takes a deliberate click.
        delete.keyEquivalent = ""
        alert.addButton(withTitle: "取消").keyEquivalent = "\r"
        alert.alertStyle = .warning
        let finish = { (response: NSApplication.ModalResponse) in
            if response == .alertFirstButtonReturn { confirmed() }
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: finish) } else { finish(alert.runModal()) }
    }
}
