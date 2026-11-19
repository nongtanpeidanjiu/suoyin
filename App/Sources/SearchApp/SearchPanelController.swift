import AppKit
import Quartz
import QuartzCore

private final class SearchPanel: NSPanel {
    /// Quick Look looks for its controller along the key window's responder
    /// chain; the window is on that chain while focus is in the search field.
    weak var previewController: SearchPanelController?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { previewController != nil }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { previewController?.beginPreview(panel) }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { previewController?.endPreview(panel) }
}

/// Top-left-origin container that also paints the glass tint and rim, so
/// both follow light and dark mode.
private final class GlassContentView: NSView {
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let dark = effectiveAppearance.isDark
        // A light wash keeps the glass bright and clear without hiding the
        // colours behind it; the rim is the highlight on the glass edge.
        layer?.backgroundColor = (dark ? NSColor.black.withAlphaComponent(0.18)
                                       : NSColor.white.withAlphaComponent(0.34)).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(dark ? 0.10 : 0.55).cgColor
    }
}

/// A rounded patch of translucent colour that follows light and dark mode.
private final class TintView: NSView {
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.09).cgColor
    }
}

/// Capsule filter button, in the manner of the system search's filter row.
private final class ChipButton: NSButton {
    var isOn = false { didSet { needsDisplay = true; refreshTitle() } }
    override var wantsUpdateLayer: Bool { true }

    convenience init(title: String, target: AnyObject, action: Selector) {
        self.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        isBordered = false
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.cornerRadius = 12
        refusesFirstResponder = true
        refreshTitle()
        let width = (title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium)]).width
        frame.size = NSSize(width: ceil(width) + 22, height: 24)
    }

    private func refreshTitle() {
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: isOn ? NSColor.labelColor : NSColor.secondaryLabelColor,
        ])
    }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(isOn ? 0.14 : 0.055).cgColor
    }
}

extension NSAppearance {
    var isDark: Bool {
        bestMatch(from: [.darkAqua, .vibrantDark, .aqua, .vibrantLight]).map { $0 == .darkAqua || $0 == .vibrantDark } ?? false
    }
}

/// The floating search panel. At rest it is a single glass capsule; typing
/// lets the same piece of glass grow downward to hold a filter row and the
/// results. The design follows the current system search.
final class SearchPanelController: NSObject, NSWindowDelegate, NSTextFieldDelegate,
                                   NSTableViewDataSource, NSTableViewDelegate,
                                   QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    private enum Layout {
        static let width: CGFloat = 640
        static let searchRow: CGFloat = 54
        /// Half the search row, so the resting panel is a true capsule.
        static let corner: CGFloat = 27
        static let filterRow: CGFloat = 34
        static let visibleRows: CGFloat = 7.5
        static let listBottom: CGFloat = 10
        static let emptyRow: CGFloat = 44
    }

    private let service: SearchService
    private let panel: SearchPanel
    private let material = NSVisualEffectView()
    private let content = GlassContentView()
    private let field = NSTextField()
    private var nameChip: ChipButton!
    private var pathChip: ChipButton!
    private let countLabel = NSTextField(labelWithString: "")
    private let scroll = NSScrollView()
    private let table = ResultTable()
    private let selectionPill = TintView()
    private let emptyLabel = NSTextField(labelWithString: "没有找到匹配的文件")

    private let queryQueue = DispatchQueue(label: "interface.query", qos: .userInteractive)
    private var generation = 0
    private var hits: [SearchHit] = []
    private var total = 0
    private var totalIsExact = true
    /// The height the panel is at or animating towards; `panel.frame` lags during a resize.
    private var targetHeight: CGFloat = 0
    private var terms: [String] = []
    private var searchesPath = false
    private var topEdge: CGFloat = 0
    private var lastDismissal = Date.distantPast
    private(set) var isVisible = false
    /// The Quick Look panel while this controller drives it.
    private var previewPanel: QLPreviewPanel?
    /// Set from the moment a preview is asked for until it has closed, so the
    /// panel does not dismiss itself when Quick Look takes key status.
    private var previewRequested = false
    /// The file Quick Look was last given, so background refreshes of the
    /// list do not reload an unchanged preview.
    private var previewedPath: String?
    private var reloadingResults = false
    /// Asked to open the settings window (Command-comma in the panel).
    var onOpenSettings: (() -> Void)?
    /// The user's key for Quick Look; Command-Y always works as well.
    var previewShortcut = ShortcutRole.preview.standard {
        didSet { showPreviewShortcutInMenu() }
    }
    private var previewMenuItem: NSMenuItem?

    init(service: SearchService) {
        self.service = service
        panel = SearchPanel(contentRect: NSRect(x: 0, y: 0, width: Layout.width, height: Layout.searchRow),
                            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                            backing: .buffered, defer: true)
        super.init()
        panel.previewController = self
        ResultCellView.compact = false
        ResultCellView.invertsWhenChosen = false
        buildWindow()
        buildContent()
        prewarm()
        NotificationCenter.default.addObserver(forName: Preferences.searchOptionsChanged, object: nil,
                                               queue: .main) { [weak self] _ in self?.refresh() }
    }

    /// Puts the window on screen once, fully transparent, so the first real
    /// appearance does not pay for creating the window's backing and blur.
    private func prewarm() {
        panel.alphaValue = 0
        panel.ignoresMouseEvents = true
        panel.orderFrontRegardless()
        panel.displayIfNeeded()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, !self.isVisible else { return }
            self.panel.orderOut(nil)
            self.panel.ignoresMouseEvents = false
        }
    }

    // MARK: Construction

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let side = radius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    private func buildWindow() {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.animationBehavior = .none
        panel.delegate = self

        material.material = .popover
        material.blendingMode = .behindWindow
        material.state = .active
        material.wantsLayer = true
        // Clip with a mask image, not a layer corner radius: a layer mask
        // leaves the blur and the window shadow rectangular.
        material.maskImage = Self.roundedMask(radius: Layout.corner)
        panel.contentView = material

        content.frame = material.bounds
        content.autoresizingMask = [.width, .height]
        content.wantsLayer = true
        content.layer?.cornerRadius = Layout.corner
        content.layer?.masksToBounds = true
        material.addSubview(content)
    }

    private func buildContent() {
        let width = Layout.width

        let glass = NSImageView(frame: NSRect(x: 19, y: (Layout.searchRow - 24) / 2, width: 24, height: 24))
        glass.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        glass.symbolConfiguration = .init(pointSize: 19, weight: .regular)
        glass.contentTintColor = .secondaryLabelColor
        content.addSubview(glass)

        field.frame = NSRect(x: 52, y: (Layout.searchRow - 30) / 2, width: width - 52 - 24, height: 30)
        field.autoresizingMask = [.width]
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 23, weight: .regular)
        field.placeholderString = "搜索文件"
        field.lineBreakMode = .byTruncatingHead
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.delegate = self
        field.setAccessibilityLabel("搜索")
        content.addSubview(field)

        nameChip = ChipButton(title: "名称", target: self, action: #selector(chooseName))
        pathChip = ChipButton(title: "路径", target: self, action: #selector(choosePath))
        nameChip.isOn = true
        let chipY = Layout.searchRow + (Layout.filterRow - 24) / 2 - 2
        nameChip.frame.origin = NSPoint(x: 16, y: chipY)
        pathChip.frame.origin = NSPoint(x: nameChip.frame.maxX + 6, y: chipY)
        nameChip.setAccessibilityLabel("按名称搜索")
        pathChip.setAccessibilityLabel("按完整路径搜索")
        for chip in [nameChip!, pathChip!] {
            chip.isHidden = true
            content.addSubview(chip)
        }

        countLabel.font = .systemFont(ofSize: 11.5)
        countLabel.textColor = .tertiaryLabelColor
        countLabel.alignment = .right
        countLabel.frame = NSRect(x: width - 20 - 300, y: chipY + 5, width: 300, height: 15)
        countLabel.autoresizingMask = [.minXMargin]
        countLabel.isHidden = true
        content.addSubview(countLabel)

        let column = NSTableColumn(identifier: .init("result"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = ResultCellView.rowHeight
        table.style = .plain
        table.selectionHighlightStyle = .none
        table.backgroundColor = .clear
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.allowsEmptySelection = false
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openSelection)
        table.rowMenu = makeRowMenu()
        showPreviewShortcutInMenu()
        table.setDraggingSourceOperationMask([.copy, .link, .generic], forLocal: false)
        installCopyShortcut()
        installOutsideDismissal()
        table.refusesFirstResponder = true

        selectionPill.wantsLayer = true
        selectionPill.layer?.cornerRadius = 12
        selectionPill.layer?.cornerCurve = .continuous
        selectionPill.isHidden = true
        table.addSubview(selectionPill, positioned: .below, relativeTo: nil)

        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        scroll.frame = NSRect(x: 0, y: Layout.searchRow + Layout.filterRow, width: width, height: 0)
        // Height is set by hand in layoutForCurrentHeight. A flexible height here
        // turns into a layout constraint that stops the window shrinking back
        // to the capsule once the list has been shown.
        scroll.autoresizingMask = [.width]
        scroll.isHidden = true
        content.addSubview(scroll)

        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.frame = NSRect(x: 0, y: Layout.searchRow + Layout.filterRow + 8, width: width, height: 18)
        emptyLabel.autoresizingMask = [.width]
        emptyLabel.isHidden = true
        content.addSubview(emptyLabel)
    }

    private func makeRowMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "打开", action: #selector(openSelection), keyEquivalent: "").target = self
        menu.addItem(withTitle: "在访达中显示", action: #selector(revealSelection), keyEquivalent: "").target = self
        let preview = menu.addItem(withTitle: "快速查看", action: #selector(showPreview), keyEquivalent: "")
        preview.target = self
        previewMenuItem = preview
        menu.addItem(.separator())
        menu.addItem(withTitle: "复制完整路径", action: #selector(copyPath), keyEquivalent: "").target = self
        menu.addItem(withTitle: "复制名称", action: #selector(copyName), keyEquivalent: "").target = self
        return menu
    }

    /// The row menu lists the current preview key next to “快速查看”. The
    /// menu exists only while it is open, so the key does not act through it.
    private func showPreviewShortcutInMenu() {
        guard let item = previewMenuItem else { return }
        let equivalent = previewShortcut.menuKeyEquivalent
        item.keyEquivalent = equivalent?.key ?? ""
        item.keyEquivalentModifierMask = equivalent?.modifiers ?? []
    }

    // MARK: Showing and hiding

    /// `anchor` is the menu bar button's screen frame when invoked from the
    /// status item; nil when invoked by the shortcut.
    func toggle(anchor: NSRect?) {
        if isVisible { hide(); return }
        // A click on the status item first takes key status away, which
        // already dismissed the panel; do not reopen it on the same click.
        if anchor != nil, Date().timeIntervalSince(lastDismissal) < 0.25 { return }
        show(anchor: anchor)
    }

    func show(anchor: NSRect?) {
        let screen = anchor.flatMap { rect in
            NSScreen.screens.first { $0.frame.contains(NSPoint(x: rect.midX, y: rect.midY)) }
        } ?? NSScreen.main ?? NSScreen.screens[0]
        let area = screen.visibleFrame
        // The field is the source of truth; results from an earlier session may be stale.
        terms = queryTerms(field.stringValue)
        if terms.isEmpty { hits = []; total = 0; table.reloadData() }
        let height = desiredHeight()
        targetHeight = height
        resizeTimer?.invalidate()
        resizeTimer = nil
        debugLog("show height=\(height) text='\(field.stringValue)'")

        // The capsule rests about a third of the way down and the list
        // grows beneath it, so the search row never moves while typing. On
        // short screens it rides higher so the full list still fits.
        let expanded = Layout.searchRow + Layout.filterRow
            + Layout.visibleRows * ResultCellView.rowHeight + Layout.listBottom
        var top = area.maxY - (area.height * 0.31).rounded()
        top = min(max(top, area.minY + 24 + expanded), area.maxY - 16)
        topEdge = top
        panel.setFrame(NSRect(x: (area.midX - Layout.width / 2).rounded(), y: top - height,
                              width: Layout.width, height: height), display: true)
        layoutForCurrentHeight()

        isVisible = true
        panel.ignoresMouseEvents = false
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
        updateFooter()
        if hasQuery { runQuery(keepingSelection: true) }
        // Animate on the next run loop turn, once the window is ordered in
        // and laid out, so that work does not eat the first frames.
        DispatchQueue.main.async { [weak self] in self?.animateIn() }
    }

    /// Fade plus a small settle, driven entirely by the render server: the
    /// window itself does not move, which keeps every frame on time.
    private func animateIn() {
        guard isVisible else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Motion.reduced ? 0.1 : Motion.appear
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
        guard !Motion.reduced, let layer = material.layer else { return }
        let size = material.bounds.size
        var from = CATransform3DMakeTranslation(size.width / 2, size.height / 2 - 6, 0)
        from = CATransform3DScale(from, 0.965, 0.965, 1)
        from = CATransform3DTranslate(from, -size.width / 2, -size.height / 2, 0)
        let settle = CASpringAnimation(keyPath: "transform")
        settle.fromValue = from
        settle.toValue = CATransform3DIdentity
        settle.mass = 1
        settle.stiffness = 520
        settle.damping = 34
        settle.duration = settle.settlingDuration
        layer.add(settle, forKey: "appear")
    }

    func hide() {
        guard isVisible else { return }
        isVisible = false
        lastDismissal = Date()
        closePreview()
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Motion.reduced ? 0.1 : Motion.dismiss
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, !self.isVisible else { return }
            self.panel.orderOut(nil)
        })
    }

    func windowDidResignKey(_ notification: Notification) {
        // `--pin` keeps the panel open while it is being inspected by testing tools.
        // Quick Look taking key status is not a reason to go away.
        guard !CommandLine.arguments.contains("--pin"), !previewRequested, !isPreviewShown else { return }
        hide()
    }

    func windowDidMove(_ notification: Notification) {
        topEdge = panel.frame.maxY
    }

    // MARK: Sizing

    private var hasQuery: Bool { !terms.isEmpty }

    private func desiredHeight() -> CGFloat {
        guard hasQuery else { return Layout.searchRow }
        if hits.isEmpty { return Layout.searchRow + Layout.filterRow + Layout.emptyRow }
        let rows = min(CGFloat(hits.count), Layout.visibleRows)
        return Layout.searchRow + Layout.filterRow + rows * ResultCellView.rowHeight + Layout.listBottom
    }

    private func showExpandedParts() {
        nameChip.isHidden = !hasQuery
        pathChip.isHidden = !hasQuery
        countLabel.isHidden = !hasQuery
        scroll.isHidden = !hasQuery || hits.isEmpty
        emptyLabel.isHidden = !hasQuery || !hits.isEmpty
    }

    private func layoutForCurrentHeight() {
        showExpandedParts()
        let top = Layout.searchRow + Layout.filterRow
        // The list stops short of the bottom so the last row clears the round corner.
        let listHeight = max(0, content.bounds.height - top - Layout.listBottom)
        scroll.frame = NSRect(x: 0, y: top, width: content.bounds.width, height: listHeight)
    }

    private var resizeTimer: Timer?

    /// Moves the panel to the height its content needs. One timer drives the
    /// change and always heads for the latest target, so quick successive
    /// changes (type, then delete) cannot leave the panel at a stale height.
    private func resizeToFit() {
        let height = desiredHeight()
        debugLog("resizeToFit want=\(height) target=\(targetHeight) frame=\(panel.frame.height) visible=\(isVisible) text='\(field.stringValue)' terms=\(terms.count) hits=\(hits.count)")
        guard abs(targetHeight - height) > 0.5 else { layoutForCurrentHeight(); return }
        targetHeight = height
        // Swap the list and the empty-state line first, so the right content
        // is on screen during the resize.
        showExpandedParts()
        resizeTimer?.invalidate()
        resizeTimer = nil
        guard isVisible, !Motion.reduced else { applyHeight(height); finishResize(); return }

        let start = panel.frame.height
        let began = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let t = min(1, (CACurrentMediaTime() - began) / Motion.resize)
            let eased = 1 - pow(1 - t, 3)
            self.applyHeight(start + (self.targetHeight - start) * CGFloat(eased))
            if t >= 1 {
                timer.invalidate()
                self.resizeTimer = nil
                self.finishResize()
            }
        }
        resizeTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func debugLog(_ text: @autoclosure () -> String) {
        guard let path = ProcessInfo.processInfo.environment["FILESEARCH_DEBUG_LOG"] else { return }
        let line = String(format: "%.3f ", CACurrentMediaTime()) + text() + "\n"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile(); handle.write(Data(line.utf8)); handle.closeFile()
        } else { try? line.write(toFile: path, atomically: true, encoding: .utf8) }
    }

    private func applyHeight(_ height: CGFloat) {
        var frame = panel.frame
        frame.origin.y = topEdge - height
        frame.size.height = height
        panel.setFrame(frame, display: true)
        layoutForCurrentHeight()
    }

    private func finishResize() {
        applyHeight(targetHeight)
        debugLog("finish target=\(targetHeight) frame=\(panel.frame.height)")
        panel.invalidateShadow()
    }

    // MARK: Query

    func controlTextDidChange(_ notification: Notification) { runQuery() }

    /// Used by the `--query` launch argument for previews and screenshots.
    func prefill(_ text: String) {
        field.stringValue = text
        runQuery()
    }

    /// Renders the panel's own views to a PNG, without the blur behind it.
    func snapshot(to path: String) {
        guard let rep = material.bitmapImageRepForCachingDisplay(in: material.bounds) else { return }
        material.cacheDisplay(in: material.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    /// Called when the index content changed.
    func refresh() {
        // Nothing to update while hidden or empty; `show` re-runs the query.
        guard isVisible, !field.stringValue.isEmpty else { return }
        runQuery(keepingSelection: true)
    }

    @objc private func chooseName() { setScope(path: false) }
    @objc private func choosePath() { setScope(path: true) }

    private func setScope(path: Bool) {
        searchesPath = path
        nameChip.isOn = !path
        pathChip.isOn = path
        runQuery()
    }

    private func runQuery(keepingSelection: Bool = false) {
        generation += 1
        let token = generation
        let text = field.stringValue
        let request = SearchRequest(text: text, scope: searchesPath ? .path : .name,
                                    includeSystemFiles: Preferences.includeSystemFiles)
        let service = self.service
        queryQueue.async { [weak self] in
            let response = service.search(request)
            DispatchQueue.main.async {
                guard let self, token == self.generation else { return }
                let previousRow = self.table.selectedRow
                let previousPath = self.hits.indices.contains(previousRow) ? self.hits[previousRow].path : nil
                self.terms = queryTerms(text)
                self.hits = response.hits
                self.total = response.total
                self.totalIsExact = response.totalIsExact
                // Reloading passes the selection through the first row on the
                // way back to the user's row; the preview follows only the end.
                self.reloadingResults = true
                self.table.reloadData()
                if keepingSelection, let previousPath,
                   let row = response.hits.firstIndex(where: { $0.path == previousPath }) {
                    // A background refresh must not move the user's place in the list.
                    self.table.selectRowIndexes([row], byExtendingSelection: false)
                } else if !response.hits.isEmpty {
                    self.table.selectRowIndexes([0], byExtendingSelection: false)
                    self.table.scrollRowToVisible(0)
                }
                self.placeSelection(animated: false)
                self.updateFooter()
                self.resizeToFit()
                self.reloadingResults = false
                self.followSelectionInPreview()
            }
        }
    }

    /// Refreshes the quiet status text at the right of the filter row.
    func updateFooter() {
        let shown = totalIsExact ? total : max(total - 1, 0)
        let count = NumberFormatter.localizedString(from: NSNumber(value: shown), number: .decimal)
        var text = totalIsExact ? "\(count) 个结果" : "超过 \(count) 个结果"
        switch service.status.phase {
        case .starting: text = "正在准备索引"
        case .scanning(let indexed):
            let done = NumberFormatter.localizedString(from: NSNumber(value: indexed), number: .decimal)
            text = "正在建立索引，已收录 \(done) 个"
        case .recovering: text += " · 正在更新索引"
        case .supplementing(let volume): text += " · 正在补充 \(volume)"
        case .degraded(let reason): text += " · \(reason)"
        case .ready: break
        }
        if service is DemoSearchService { text += " · 演示数据" }
        guard countLabel.stringValue != text else { return }
        if countLabel.isHidden || Motion.reduced {
            countLabel.stringValue = text
            return
        }
        let fade = CATransition()
        fade.type = .fade
        fade.duration = Motion.statusFade
        countLabel.wantsLayer = true
        countLabel.layer?.add(fade, forKey: "status")
        countLabel.stringValue = text
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { hits.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("cell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? ResultCellView ?? {
            let view = ResultCellView(frame: .zero)
            view.identifier = identifier
            return view
        }()
        cell.configure(hits[row], terms: terms)
        cell.isChosen = row == tableView.selectedRow
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        placeSelection(animated: true)
        followSelectionInPreview()
    }

    /// Slides the soft highlight to the selected row. The slide is short
    /// enough to feel like the key press itself.
    private func placeSelection(animated: Bool) {
        let row = table.selectedRow
        guard hits.indices.contains(row) else { selectionPill.isHidden = true; return }
        let target = table.rect(ofRow: row).insetBy(dx: 8, dy: 0)
        if selectionPill.isHidden || !animated || Motion.reduced {
            selectionPill.isHidden = false
            selectionPill.frame = target
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.11
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.2, 1)
            context.allowsImplicitAnimation = true
            selectionPill.animator().frame = target
        }
    }

    /// Every action works on the selected row. A right click selects the row
    /// under the pointer first, so its menu acts on that row, and the keys
    /// used afterwards act on whatever is selected then.
    private var selectedHit: SearchHit? {
        hits.indices.contains(table.selectedRow) ? hits[table.selectedRow] : nil
    }

    @objc private func openSelection() {
        guard let hit = selectedHit else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: hit.path))
        hide()
    }

    @objc private func revealSelection() {
        guard let hit = selectedHit else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: hit.path)])
        hide()
    }

    /// Lets a result row be dragged into other applications as a file.
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        hits.indices.contains(row) ? NSURL(fileURLWithPath: hits[row].path) : nil
    }

    /// Closes the panel when the user clicks anywhere outside it or switches
    /// to another application. Losing key status alone is not reliable for a
    /// non-activating panel owned by a background application.
    private func installOutsideDismissal() {
        guard !CommandLine.arguments.contains("--pin") else { return }
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            self?.hide()
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if app?.processIdentifier != ProcessInfo.processInfo.processIdentifier { self?.hide() }
        }
    }

    /// The keys the panel acts on before the search field sees them: the
    /// preview key, and the fixed keys with a panel action in PanelKeys.
    /// The arrows, Return, Tab and Esc come through the field's text
    /// system instead (see `control(_:textView:doCommandBy:)`).
    private func installCopyShortcut() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isVisible else { return event }
            let inPanel = event.window === self.panel
            let action = PanelKeys.action(for: event)
            // The preview key and Command-Y open and close Quick Look, also
            // while its panel has key status. The preview key is caught even
            // without a selection, so that Option-Space and the like never
            // type a character into the field.
            let isPreviewKey = self.previewShortcut.matches(event)
            if isPreviewKey || action == .quickLook, inPanel || event.window is QLPreviewPanel {
                if self.isPreviewShown || self.selectedHit != nil {
                    self.togglePreview()
                    return nil
                }
                return isPreviewKey ? nil : event
            }
            guard inPanel, let action else { return event }
            switch action {
            case .settings:
                self.hide()
                self.onOpenSettings?()
                return nil
            case .reveal:
                // The field editor never turns Command-Return into a command.
                guard self.selectedHit != nil else { return event }
                self.revealSelection()
                return nil
            case .copyPath:
                // Selected text in the field is copied as usual.
                guard (self.field.currentEditor()?.selectedRange.length ?? 0) == 0,
                      self.selectedHit != nil else { return event }
                self.copyPath()
                return nil
            case .quickLook:
                return event
            }
        }
    }

    @objc private func copyPath() { copy(selectedHit?.path) }
    @objc private func copyName() { copy(selectedHit?.name) }

    private func copy(_ text: String?) {
        guard let text else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func moveSelection(by delta: Int) {
        guard !hits.isEmpty else { return }
        let row = min(max(table.selectedRow + delta, 0), hits.count - 1)
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    // MARK: Quick Look

    private var isPreviewShown: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible
    }

    /// The preview key and Command-Y: opens Quick Look on the selected file, or
    /// closes it when it is already open.
    @objc func togglePreview() {
        if isPreviewShown { closePreview() } else { showPreview() }
    }

    /// Opens Quick Look on the selected file without taking focus from the
    /// search field, so typing and the arrow keys keep working on the list.
    @objc private func showPreview() {
        guard isVisible, selectedHit != nil, let quickLook = QLPreviewPanel.shared() else { return }
        previewRequested = true
        // Quick Look finds its controller through the key window, so the
        // search panel must hold key status when the preview is asked for.
        if !panel.isKeyWindow { refocusField() }
        if previewPanel == nil { quickLook.updateController() }
        debugLog("preview key=\(panel.isKeyWindow) controller=\(previewPanel != nil)")
        // Above the search panel, which floats over ordinary windows.
        quickLook.level = NSWindow.Level(rawValue: panel.level.rawValue + 1)
        quickLook.reloadData()
        if !quickLook.isVisible { quickLook.orderFront(nil) }
        // Without a controller there is nothing to show; do not leave the
        // panel unable to dismiss itself.
        guard previewPanel != nil else { closePreview(); previewRequested = false; return }
        // Ordering Quick Look in can leave it holding key status; give it back.
        if !panel.isKeyWindow { refocusField() }
    }

    /// Shows the newly selected file in the open preview.
    private func followSelectionInPreview() {
        guard !reloadingResults, let previewPanel, selectedHit?.path != previewedPath else { return }
        previewPanel.reloadData()
    }

    private func closePreview() {
        guard isPreviewShown else { previewRequested = false; return }
        QLPreviewPanel.shared().orderOut(nil)
    }

    /// Returns the keyboard to the search field without selecting its text.
    private func refocusField() {
        guard isVisible else { return }
        panel.makeKey()
        if field.currentEditor() == nil {
            panel.makeFirstResponder(field)
            let end = (field.stringValue as NSString).length
            field.currentEditor()?.selectedRange = NSRange(location: end, length: 0)
        }
    }

    fileprivate func beginPreview(_ quickLook: QLPreviewPanel) {
        debugLog("beginPreview")
        previewPanel = quickLook
        quickLook.dataSource = self
        quickLook.delegate = self
    }

    fileprivate func endPreview(_ quickLook: QLPreviewPanel) {
        debugLog("endPreview visible=\(quickLook.isVisible)")
        previewPanel = nil
        quickLook.dataSource = nil
        quickLook.delegate = nil
        previewedPath = nil
        let wasRequested = previewRequested
        previewRequested = false
        // Closing the preview (Esc or Space in its own panel, or its close
        // button) hands the keyboard back to the search field. Quick Look
        // still counts as visible at this point, so look once it has gone.
        guard wasRequested else { return }
        DispatchQueue.main.async { [weak self] in
            if !quickLook.isVisible { self?.refocusField() }
        }
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { selectedHit == nil ? 0 : 1 }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        // A file that is gone or unreadable gets Quick Look's own notice.
        previewedPath = selectedHit?.path
        return selectedHit.map { NSURL(fileURLWithPath: $0.path) }
    }

    /// While Quick Look holds key status, the keys that steer the list still do.
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch event.keyCode {
        case 125: moveSelection(by: 1)
        case 126: moveSelection(by: -1)
        case 36, 76: flags.contains(.command) ? revealSelection() : openSelection()
        default: return false
        }
        return true
    }

    /// Lets Quick Look zoom out of, and back into, the selected row.
    func previewPanel(_ quickLook: QLPreviewPanel!, sourceFrameOnScreenFor item: QLPreviewItem!) -> NSRect {
        let row = table.selectedRow
        guard isVisible, hits.indices.contains(row) else { return .zero }
        let rect = table.rect(ofRow: row)
        guard table.visibleRect.intersects(rect) else { return .zero }
        return self.panel.convertToScreen(table.convert(rect, to: nil))
    }

    /// Test hook: moves the selection the way the arrow keys do.
    func moveSelectionForTesting(by delta: Int) { moveSelection(by: delta) }

    // MARK: Keyboard

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): moveSelection(by: 1)
        case #selector(NSResponder.moveUp(_:)): moveSelection(by: -1)
        case #selector(NSResponder.scrollPageDown(_:)), #selector(NSResponder.pageDown(_:)): moveSelection(by: 7)
        case #selector(NSResponder.scrollPageUp(_:)), #selector(NSResponder.pageUp(_:)): moveSelection(by: -7)
        case #selector(NSResponder.insertNewline(_:)):
            if NSApp.currentEvent?.modifierFlags.contains(.command) == true { revealSelection() } else { openSelection() }
        case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)):
            setScope(path: !searchesPath)
        case #selector(NSResponder.cancelOperation(_:)):
            if isPreviewShown { closePreview() } else if field.stringValue.isEmpty { hide() } else {
                field.stringValue = ""
                runQuery()
            }
        default: return false
        }
        return true
    }
}

/// The results table. A right click moves the ordinary selection, and with it
/// the soft highlight, to the row under the pointer before the menu opens,
/// instead of the system's blue outline around a separately tracked row.
private final class ResultTable: NSTableView {
    var rowMenu: NSMenu?

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0, let rowMenu else { return nil }
        if row != selectedRow { selectRowIndexes([row], byExtendingSelection: false) }
        return rowMenu
    }

    // The table draws its outline around the clicked row from these two;
    // leaving them out keeps the menu free of it.
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {}
    override func didCloseMenu(_ menu: NSMenu, with event: NSEvent?) {}
}
