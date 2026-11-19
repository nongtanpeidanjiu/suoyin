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
/// With `opensMenu` it carries a small chevron after its title, for a chip
/// that opens a list of choices rather than switching on its own.
private final class ChipButton: NSButton {
    static let font = NSFont.systemFont(ofSize: 12, weight: .medium)
    var isOn = false { didSet { needsDisplay = true; refreshTitle() } }
    private var opensMenu = false
    override var wantsUpdateLayer: Bool { true }

    convenience init(title: String, target: AnyObject, action: Selector, opensMenu: Bool = false) {
        self.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        self.opensMenu = opensMenu
        isBordered = false
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.cornerRadius = 12
        refusesFirstResponder = true
        if opensMenu {
            imagePosition = .imageTrailing
            imageHugsTitle = true
        }
        setLabel(title)
    }

    /// Changes the title and fits the capsule around it; the left edge stays.
    func setLabel(_ text: String) {
        title = text
        refreshTitle()
        let width = ceil((text as NSString).size(withAttributes: [.font: Self.font]).width)
        frame.size = NSSize(width: width + (opensMenu ? 34 : 22), height: 24)
    }

    private func refreshTitle() {
        let color = isOn ? NSColor.labelColor : NSColor.secondaryLabelColor
        attributedTitle = NSAttributedString(string: title, attributes: [.font: Self.font, .foregroundColor: color])
        guard opensMenu else { return }
        image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 8, weight: .bold))
        contentTintColor = color
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
        /// Room under the empty-state line for “重试” when the core is down.
        static let retryRow: CGFloat = 34
        static let sideInset: CGFloat = 16
        /// Between the scope chips and the kind chip: two separate choices.
        static let groupGap: CGFloat = 14
        static let countGap: CGFloat = 12
        static let countFont = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
        /// Quick Look docked at the panel's right while the screen is wide enough.
        static let previewWidth: CGFloat = 560
        static let previewGap: CGFloat = 12
        static let previewMinHeight: CGFloat = 360
        static let screenMargin: CGFloat = 24
    }

    private let service: SearchService
    private let panel: SearchPanel
    private let material = NSVisualEffectView()
    private let content = GlassContentView()
    private let field = NSTextField()
    private var nameChip: ChipButton!
    private var pathChip: ChipButton!
    private var kindChip: ChipButton!
    private var kind: SearchKind = .any
    private let countLabel = NSTextField(labelWithString: "")
    private let scroll = NSScrollView()
    private let table = ResultTable()
    private let selectionPill = TintView()
    private let emptyLabel = NSTextField(labelWithString: "没有找到匹配的文件")
    private let retryButton = NSButton(title: "重试", target: nil, action: nil)
    /// A short notice over the bottom of the list, such as for a file that
    /// has gone; it fades by itself.
    private let notice = NoticeView()
    private var noticeTimer: Timer?

    private let queryQueue = DispatchQueue(label: "interface.query", qos: .userInteractive)
    /// Bumped by every new query; answers and pages for an older one are dropped.
    private var generation = 0 {
        didSet { generationLock.withLock { sharedGeneration = generation } }
    }
    private var hits: [SearchHit] = []
    /// The paths in `hits`, so that a page overlapping the last never shows
    /// a file twice.
    private var loadedPaths: Set<String> = []
    private var total = 0
    private var totalIsExact = true
    /// The query `hits` answer, for asking for the next page of it.
    private var lastRequest: SearchRequest?
    /// Rows the core has returned for it so far, duplicates included: the
    /// offset of the next page.
    private var fetchedCount = 0
    /// The next page has been asked for and not yet arrived.
    private var loadingMore = false
    /// The core said there is nothing after what is loaded.
    private var reachedEnd = true

    private enum Paging {
        static let pageSize = 200
        /// Rows kept in memory at most; past this the user is asked to narrow
        /// the search instead.
        static let maxLoaded = 5_000
        /// Rows from the end at which the next page is asked for.
        static let lookahead = 40
        /// Matches the first query counts at most, to give an exact total.
        static let countBudget = 500
    }
    /// The height the panel is at or animating towards; `panel.frame` lags during a resize.
    private var targetHeight: CGFloat = 0
    private var terms: [String] = []
    private var searchesPath = false
    private var topEdge: CGFloat = 0
    /// Where the panel rests when no preview is docked: centred when shown,
    /// then wherever the user drags it.
    private var homeX: CGFloat = 0
    private var userPlaced = false
    /// The origin of the panel's last programmatic move, so `windowDidMove`
    /// can tell those apart from the user dragging the panel.
    private var lastSetOrigin: NSPoint?
    /// The panel's left edge while Quick Look is docked beside it; nil when
    /// the preview is not docked (closed, or the screen is too narrow).
    private var dockedX: CGFloat?
    /// Docked at some point since Quick Look last opened; it then neither
    /// zooms in from nor back into the row.
    private var previewWasDocked = false
    private var slideTimer: Timer?
    private var placingPreview = false
    private var previewObservers: [NSObjectProtocol] = []
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
    /// Stand-ins that let Quick Look show text it has no preview for.
    private let previewContent = PreviewContent()
    /// Test hook: a file to preview instead of the selected row, until the
    /// selection moves.
    private var previewPathOverride: String?
    /// The file the preview shows.
    private var previewTarget: String? { previewPathOverride ?? selectedHit?.path }
    private var reloadingResults = false
    /// Asked to open the settings window (Command-comma in the panel).
    var onOpenSettings: (() -> Void)?
    /// “重试” while the core could not be opened.
    var onRetry: (() -> Void)?
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
        kindChip = ChipButton(title: "类型", target: self, action: #selector(showKindMenu), opensMenu: true)
        kindChip.frame.origin = NSPoint(x: pathChip.frame.maxX + Layout.groupGap, y: chipY)
        for chip in [nameChip!, pathChip!, kindChip!] {
            chip.isHidden = true
            content.addSubview(chip)
        }

        countLabel.font = Layout.countFont
        countLabel.textColor = .tertiaryLabelColor
        countLabel.alignment = .right
        countLabel.lineBreakMode = .byClipping
        countLabel.cell?.usesSingleLineMode = true
        countLabel.frame = NSRect(x: 0, y: chipY + 5, width: 0, height: 15)
        countLabel.isHidden = true
        content.addSubview(countLabel)
        showKind()

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
        // Scrolling near the end asks for the next page.
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                                               object: scroll.contentView, queue: .main) { [weak self] _ in
            self?.loadMoreIfNeeded()
        }

        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.frame = NSRect(x: 0, y: Layout.searchRow + Layout.filterRow + 8, width: width, height: 18)
        emptyLabel.autoresizingMask = [.width]
        emptyLabel.lineBreakMode = .byTruncatingMiddle
        emptyLabel.isHidden = true
        content.addSubview(emptyLabel)

        retryButton.target = self
        retryButton.action = #selector(retry)
        retryButton.bezelStyle = .rounded
        retryButton.controlSize = .small
        retryButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        retryButton.refusesFirstResponder = true
        retryButton.sizeToFit()
        retryButton.frame.origin = NSPoint(x: ((width - retryButton.frame.width) / 2).rounded(),
                                           y: Layout.searchRow + Layout.filterRow + 34)
        retryButton.autoresizingMask = [.minXMargin, .maxXMargin]
        retryButton.isHidden = true
        content.addSubview(retryButton)

        notice.isHidden = true
        content.addSubview(notice)
    }

    @objc private func retry() { onRetry?() }

    /// Shows `text` for a moment over the bottom of the panel.
    private func showNotice(_ text: String) {
        notice.text = text
        let size = notice.fittingSize
        let bottom = max(content.bounds.height - Layout.listBottom - 6, Layout.searchRow + size.height)
        notice.frame = NSRect(x: ((content.bounds.width - size.width) / 2).rounded(), y: bottom - size.height,
                              width: size.width, height: size.height)
        notice.isHidden = false
        notice.alphaValue = 1
        notice.setAccessibilityLabel(text)
        NSAccessibility.post(element: notice, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        noticeTimer?.invalidate()
        noticeTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { [weak self] _ in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = Motion.reduced ? 0.1 : 0.25
                self.notice.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                guard let self, self.notice.alphaValue == 0 else { return }
                self.notice.isHidden = true
            })
        }
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
        // Every search starts from all kinds, so a kind picked last time can
        // never hide what the user is looking for now.
        if kind != .any { kind = .any; showKind() }
        // The field is the source of truth; results from an earlier session may be stale.
        terms = queryTerms(field.stringValue)
        if terms.isEmpty { clearResults(); table.reloadData() }
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
        homeX = (area.midX - Layout.width / 2).rounded()
        userPlaced = false
        dockedX = nil
        slideTimer?.invalidate()
        slideTimer = nil
        setPanelFrame(NSRect(x: homeX, y: top - height, width: Layout.width, height: height))
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
        guard !TestHooks.flag("--pin"), !previewRequested, !isPreviewShown else { return }
        hide()
    }

    /// Only a move the user made counts; the panel's own resizing and its
    /// slide beside the preview set `lastSetOrigin` first.
    func windowDidMove(_ notification: Notification) {
        let frame = panel.frame
        if let set = lastSetOrigin, abs(set.x - frame.minX) < 0.5, abs(set.y - frame.minY) < 0.5 { return }
        topEdge = frame.maxY
        homeX = frame.minX
        userPlaced = true
        // A drag while the preview is docked ends the slide; the preview
        // follows the panel, and closing it leaves the panel where it was put.
        guard dockedX != nil else { return }
        slideTimer?.invalidate()
        slideTimer = nil
        dockedX = frame.minX
        placePreview()
    }

    /// Every programmatic frame change goes through here.
    private func setPanelFrame(_ frame: NSRect) {
        lastSetOrigin = frame.origin
        panel.setFrame(frame, display: true)
    }

    // MARK: Sizing

    private var hasQuery: Bool { !terms.isEmpty }

    /// The core could not be opened: the empty state says so and offers “重试”.
    private var isUnavailable: Bool { service.status.phase.isUnavailable }

    private func desiredHeight() -> CGFloat {
        guard hasQuery else { return Layout.searchRow }
        if hits.isEmpty {
            return Layout.searchRow + Layout.filterRow + Layout.emptyRow + (isUnavailable ? Layout.retryRow : 0)
        }
        let rows = min(CGFloat(hits.count), Layout.visibleRows)
        return Layout.searchRow + Layout.filterRow + rows * ResultCellView.rowHeight + Layout.listBottom
    }

    private func showExpandedParts() {
        nameChip.isHidden = !hasQuery
        pathChip.isHidden = !hasQuery
        kindChip.isHidden = !hasQuery
        countLabel.isHidden = !hasQuery
        scroll.isHidden = !hasQuery || hits.isEmpty
        emptyLabel.isHidden = !hasQuery || !hits.isEmpty
        let status = service.status
        if case .unavailable(let reason) = status.phase {
            emptyLabel.stringValue = reason
            emptyLabel.toolTip = reason
        } else if case .waitingForSetup = status.phase {
            emptyLabel.stringValue = IndexPhase.waitingLine
            emptyLabel.toolTip = nil
        } else if let failure = status.phase.failure {
            // Not finding it may be the error's doing.
            emptyLabel.stringValue = "没有找到匹配的文件。\(failure.title)，结果可能不全，详见“设置 › 索引”"
            emptyLabel.toolTip = failure.text(.index)
        } else {
            emptyLabel.stringValue = "没有找到匹配的文件"
            emptyLabel.toolTip = nil
        }
        retryButton.isHidden = emptyLabel.isHidden || !status.phase.isUnavailable
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
        guard let path = TestHooks.debugLogPath else { return }
        let line = String(format: "%.3f ", CACurrentMediaTime()) + text() + "\n"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile(); handle.write(Data(line.utf8)); handle.closeFile()
        } else { try? line.write(toFile: path, atomically: true, encoding: .utf8) }
    }

    private func applyHeight(_ height: CGFloat) {
        var frame = panel.frame
        frame.origin.y = topEdge - height
        frame.size.height = height
        setPanelFrame(frame)
        layoutForCurrentHeight()
        placePreview()
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
        guard isVisible, !field.stringValue.isEmpty else { resizeToFit(); return }
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

    // MARK: Kind filter

    /// The kinds open as a menu under the chip: eight capsules do not fit
    /// the row, and a menu shows every choice with its key in one place.
    @objc private func showKindMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (index, choice) in SearchKind.allCases.enumerated() {
            let item = NSMenuItem(title: choice.title, action: #selector(chooseKind(_:)), keyEquivalent: "\(index + 1)")
            item.keyEquivalentModifierMask = .command
            item.target = self
            item.tag = index
            item.state = choice == kind ? .on : .off
            item.image = NSImage(systemSymbolName: choice.symbol, accessibilityDescription: nil)
            menu.addItem(item)
            if choice == .any { menu.addItem(.separator()) }
        }
        let below = kindChip.isFlipped ? kindChip.bounds.maxY + 4 : -4
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: below), in: kindChip)
    }

    @objc private func chooseKind(_ sender: NSMenuItem) {
        let all = SearchKind.allCases
        if all.indices.contains(sender.tag) { setKind(all[sender.tag]) }
    }

    private func setKind(_ choice: SearchKind) {
        guard choice != kind else { return }
        kind = choice
        showKind()
        runQuery()
    }

    /// The chip reads “类型” while every kind is shown, and names the kind,
    /// with the darker fill of a chosen chip, once one is picked.
    private func showKind() {
        kindChip.setLabel(kind == .any ? "类型" : kind.title)
        kindChip.isOn = kind != .any
        kindChip.setAccessibilityLabel("按类型筛选，当前为\(kind.title)")
        kindChip.setAccessibilityHelp("打开类型列表；也可以按 Command 加 1 至 8 切换")
        let left = kindChip.frame.maxX + Layout.countGap
        countLabel.frame = NSRect(x: left, y: countLabel.frame.minY,
                                  width: Layout.width - Layout.sideInset - 4 - left, height: countLabel.frame.height)
        lastStatusKey = nil
        updateFooter()
    }

    private func clearResults() {
        hits = []
        loadedPaths = []
        total = 0
        totalIsExact = true
        reachedEnd = true
        lastRequest = nil
        fetchedCount = 0
    }

    /// Runs the query from the first row. A refresh of the same query
    /// (`keepingSelection`) asks again for as many rows as are loaded, so
    /// the user's place in a long list survives it.
    private func runQuery(keepingSelection: Bool = false) {
        generation += 1
        let token = generation
        loadingMore = false
        let text = field.stringValue
        var request = SearchRequest(text: normalizedQuery(text), scope: searchesPath ? .path : .name,
                                    includeSystemFiles: Preferences.includeSystemFiles, kind: kind)
        if keepingSelection {
            request.limit = min(max(Paging.pageSize, hits.count), Paging.maxLoaded)
        }
        // Counted further than the page, so that up to this many matches the
        // line gives the exact number; the next pages do without.
        request.totalCountBudget = Paging.countBudget
        let service = self.service
        queryQueue.async { [weak self] in
            // Typing queues a query per key; only the newest is worth running.
            guard let self, self.isCurrent(token) else { return }
            let response = service.search(request)
            DispatchQueue.main.async {
                guard token == self.generation else { return }
                let previousRow = self.table.selectedRow
                let previousPath = self.hits.indices.contains(previousRow) ? self.hits[previousRow].path : nil
                self.terms = queryTerms(text)
                self.hits = []
                self.loadedPaths = []
                for hit in response.hits where self.loadedPaths.insert(hit.path).inserted { self.hits.append(hit) }
                self.total = response.total
                self.totalIsExact = response.totalIsExact
                self.lastRequest = request
                self.fetchedCount = response.hits.count
                self.reachedEnd = response.hits.count < request.limit
                    || (response.totalIsExact && request.offset + response.hits.count >= response.total)
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

    /// Read on the query queue, written on the main thread; a stale read
    /// only means one query too many runs.
    private let generationLock = NSLock()
    private var sharedGeneration = 0
    private func isCurrent(_ token: Int) -> Bool { generationLock.withLock { sharedGeneration == token } }

    /// Whether more rows can be asked for: the core has more, and the list
    /// is still under its limit.
    private var canLoadMore: Bool {
        !reachedEnd && !loadingMore && lastRequest != nil && hits.count < Paging.maxLoaded
    }

    /// Asks for the next page once the visible rows come near the end.
    private func loadMoreIfNeeded() {
        guard canLoadMore, isVisible else { return }
        let lastVisible = table.rows(in: table.visibleRect).upperBound
        if lastVisible >= hits.count - Paging.lookahead { loadMore() }
    }

    private func loadMore() {
        guard canLoadMore, var request = lastRequest else { return }
        request.offset = fetchedCount
        request.totalCountBudget = nil
        request.limit = min(Paging.pageSize, Paging.maxLoaded - hits.count)
        loadingMore = true
        let token = generation
        let offset = fetchedCount
        let service = self.service
        queryQueue.async { [weak self] in
            guard let self, self.isCurrent(token) else { return }
            let response = service.search(request)
            DispatchQueue.main.async {
                // A new query, or a refresh that replaced the list, drops the page.
                guard token == self.generation, offset == self.fetchedCount else { return }
                self.loadingMore = false
                self.fetchedCount += response.hits.count
                let fresh = response.hits.filter { self.loadedPaths.insert($0.path).inserted }
                self.reachedEnd = response.hits.count < request.limit
                    || (response.totalIsExact && offset + response.hits.count >= response.total)
                // A page without the count budget knows only that one more
                // follows it; the larger lower bound of the first page stays.
                if response.totalIsExact {
                    self.total = response.total
                    self.totalIsExact = true
                } else if !self.totalIsExact {
                    self.total = max(self.total, response.total)
                }
                if !fresh.isEmpty {
                    self.hits += fresh
                    self.table.noteNumberOfRowsChanged()
                }
                self.updateFooter()
                // Rows already on screen may still reach the end, e.g. after a
                // page that was all duplicates.
                DispatchQueue.main.async { self.loadMoreIfNeeded() }
            }
        }
    }

    /// Which sort of status the line shows, so that only a change of sort
    /// fades; a count that ticks up every half second is set in place.
    private var lastStatusKey: String?

    /// Refreshes the quiet status text at the right of the filter row.
    func updateFooter() {
        // Not exact: `total` is a lower bound, at least one more than is
        // known for sure, so “超过” the number below it.
        let shown = totalIsExact ? total : max(hits.count, total - 1)
        let count = formattedCount(shown)
        var lead = totalIsExact ? "\(count) 个结果" : "超过 \(count) 个结果"
        if hits.count >= Paging.maxLoaded && !(totalIsExact && total <= hits.count) {
            lead = "只显示前 \(formattedCount(Paging.maxLoaded)) 个，请加关键词缩小范围"
        }
        // A part that may be cut in the middle when the line is too long,
        // and the rest that must stay whole.
        var name = ""
        var tail = ""
        let key: String
        switch service.status.phase {
        case .starting:
            lead = "正在准备索引"
            key = "starting"
        case .scanning(let indexed):
            lead = "正在建立索引，已收录 \(formattedCount(indexed)) 个"
            key = "scanning"
        case .recovering:
            lead += " · 正在更新索引"
            key = "recovering"
        case .supplementing(let source, let indexed, let restoring):
            // Short, the row is narrow: restoring brings back entries that
            // are searchable already, reading adds new ones.
            lead += restoring ? " · 正在恢复 " : " · 正在补充 "
            name = source
            if restoring {
                tail = indexed > 0 ? "，\(formattedCount(indexed)) 个可搜" : ""
            } else {
                tail = indexed > 0 ? "，已收录 \(formattedCount(indexed)) 个" : ""
            }
            key = (restoring ? "restoring\u{0}" : "supplementing\u{0}") + source
        case .failed(let failure):
            lead += " · "
            name = failure.title
            tail = "，详见设置"
            key = "failed"
        case .ready:
            key = "ready"
        case .waitingForSetup:
            lead = IndexPhase.waitingLine
            key = "waiting"
        case .unavailable:
            lead = "无法启动搜索"
            key = "unavailable"
        }
        let explanation = service.status.phase.failure?.text(.index)
        if countLabel.toolTip != explanation { countLabel.toolTip = explanation }
        if service.isDemo { tail += " · 演示数据" }
        let text = Self.fit(lead, name, tail, width: countLabel.frame.width)
        guard countLabel.stringValue != text else { return }
        let fades = lastStatusKey != nil && lastStatusKey != key
        lastStatusKey = key
        if !fades || countLabel.isHidden || Motion.reduced {
            countLabel.layer?.removeAnimation(forKey: "status")
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

    /// Joins the three parts, cutting `name` in the middle until the line
    /// fits `width`. The other parts carry the counts and are never cut.
    private static func fit(_ lead: String, _ name: String, _ tail: String, width: CGFloat) -> String {
        func measure(_ text: String) -> CGFloat {
            ceil((text as NSString).size(withAttributes: [.font: Layout.countFont]).width)
        }
        let whole = lead + name + tail
        guard !name.isEmpty, width > 0, measure(whole) > width else { return whole }
        let characters = Array(name)
        var low = 0, high = characters.count - 1, best = lead + "…" + tail
        // The longest middle-cut name that still fits.
        while low <= high {
            let keep = (low + high) / 2
            let head = String(characters.prefix((keep + 1) / 2))
            let end = String(characters.suffix(keep / 2))
            let candidate = lead + head + "…" + end + tail
            if measure(candidate) <= width { best = candidate; low = keep + 1 } else { high = keep - 1 }
        }
        return best
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
        guard let hit = selectedHit, stillExists(hit) else { return }
        guard NSWorkspace.shared.open(URL(fileURLWithPath: hit.path)) else {
            NSSound.beep()
            showNotice("无法打开这个文件")
            return
        }
        hide()
    }

    @objc private func revealSelection() {
        guard let hit = selectedHit, stillExists(hit) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: hit.path)])
        hide()
    }

    /// The index can lag behind the disk; a file moved or deleted since gets
    /// a word instead of no reaction at all. The panel stays open.
    private func stillExists(_ hit: SearchHit) -> Bool {
        // `lstat`, so that a symbolic link whose target is gone still counts.
        var info = stat()
        if lstat(hit.path, &info) == 0 { return true }
        NSSound.beep()
        showNotice(hit.isDirectory ? "这个文件夹已被移走或删除" : "这个文件已被移走或删除")
        return false
    }

    /// Lets a result row be dragged into other applications as a file.
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        hits.indices.contains(row) ? NSURL(fileURLWithPath: hits[row].path) : nil
    }

    /// Closes the panel when the user clicks anywhere outside it or switches
    /// to another application. Losing key status alone is not reliable for a
    /// non-activating panel owned by a background application.
    private func installOutsideDismissal() {
        guard !TestHooks.flag("--pin") else { return }
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
            case .kind(let choice):
                // Only while the filter row is showing, like the chips.
                guard self.hasQuery else { return event }
                self.setKind(choice)
                return nil
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
        if previewPathOverride != nil {
            previewPathOverride = nil
            followSelectionInPreview()
        }
        let row = min(max(table.selectedRow + delta, 0), hits.count - 1)
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
        // Moving down towards the end, or pressing down on the last row,
        // fetches the next page as scrolling does.
        if delta > 0, row >= hits.count - Paging.lookahead { loadMore() }
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
        guard isVisible, previewTarget != nil, let quickLook = QLPreviewPanel.shared() else { return }
        previewRequested = true
        // Quick Look finds its controller through the key window, so the
        // search panel must hold key status when the preview is asked for.
        if !panel.isKeyWindow { refocusField() }
        if previewPanel == nil { quickLook.updateController() }
        debugLog("preview key=\(panel.isKeyWindow) controller=\(previewPanel != nil)")
        // Above the search panel, which floats over ordinary windows.
        quickLook.level = NSWindow.Level(rawValue: panel.level.rawValue + 1)
        quickLook.reloadData()
        let opening = !quickLook.isVisible
        if opening { dockPreview() }
        if opening { quickLook.orderFront(nil) }
        // Without a controller there is nothing to show; do not leave the
        // panel unable to dismiss itself.
        guard previewPanel != nil else { closePreview(); previewRequested = false; return }
        if opening { placePreview(); settlePreview() }
        // Ordering Quick Look in can leave it holding key status; give it back.
        if !panel.isKeyWindow { refocusField() }
    }

    /// Shows the newly selected file in the open preview.
    private func followSelectionInPreview() {
        guard !reloadingResults, let previewPanel, previewTarget != previewedPath else { return }
        previewPanel.reloadData()
        placePreview()
        settlePreview()
    }

    // MARK: Docking the preview

    /// Where the panel and Quick Look go when the preview opens, or nil when
    /// the screen cannot hold both side by side with a margin on each side.
    private func dockedPanelX() -> CGFloat? {
        guard let area = (panel.screen ?? NSScreen.main)?.visibleFrame else { return nil }
        let group = Layout.width + Layout.previewGap + Layout.previewWidth
        guard area.width >= group + 2 * Layout.screenMargin else { return nil }
        // Untouched, the pair is centred; after a drag the panel stays put
        // unless the preview would run off the right edge.
        if !userPlaced { return (area.midX - group / 2).rounded() }
        let rightmost = area.maxX - Layout.screenMargin - group
        return max(area.minX + Layout.screenMargin, min(homeX, rightmost)).rounded()
    }

    /// Quick Look's frame while docked: right of the panel, tops aligned,
    /// as tall as the panel but never shorter than a useful preview.
    private func dockedPreviewFrame() -> NSRect? {
        guard let x = dockedX, let area = (panel.screen ?? NSScreen.main)?.visibleFrame else { return nil }
        let room = topEdge - area.minY
        let height = min(max(panel.frame.height, Layout.previewMinHeight), room).rounded()
        return NSRect(x: x + Layout.width + Layout.previewGap, y: topEdge - height,
                      width: Layout.previewWidth, height: height)
    }

    /// Slides the panel aside so the preview fits next to it.
    private func dockPreview() {
        guard isVisible, let x = dockedPanelX() else { dockedX = nil; previewWasDocked = false; return }
        dockedX = x
        previewWasDocked = true
        slidePanel(to: x)
    }

    /// Slides the panel back to where it rested before the preview opened.
    private func undockPreview() {
        guard dockedX != nil else { return }
        dockedX = nil
        // Hiding fades the panel out where it is; `show` places it afresh.
        guard isVisible else { slideTimer?.invalidate(); slideTimer = nil; return }
        slidePanel(to: homeX)
    }

    /// Moves the panel sideways, 0.18 s ease-out like the height changes.
    private func slidePanel(to x: CGFloat) {
        slideTimer?.invalidate()
        slideTimer = nil
        let start = panel.frame.minX
        guard abs(start - x) > 0.5 else { return }
        guard !Motion.reduced else { moveSideways(to: x); return }
        let began = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let t = min(1, (CACurrentMediaTime() - began) / Motion.resize)
            let eased = 1 - pow(1 - t, 3)
            self.moveSideways(to: (start + (x - start) * CGFloat(eased)).rounded())
            if t >= 1 {
                timer.invalidate()
                self.slideTimer = nil
                self.panel.invalidateShadow()
            }
        }
        slideTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func moveSideways(to x: CGFloat) {
        var frame = panel.frame
        frame.origin.x = x
        frame.origin.y = topEdge - frame.height
        setPanelFrame(frame)
    }

    /// Puts Quick Look in its docked place, if it is docked and not there.
    private func placePreview() {
        guard !placingPreview, isPreviewShown, let target = dockedPreviewFrame() else { return }
        let quickLook = QLPreviewPanel.shared()!
        guard !NSEqualRects(quickLook.frame.integral, target) else { return }
        placingPreview = true
        quickLook.setFrame(target, display: true, animate: false)
        placingPreview = false
        debugLog("placePreview \(target)")
    }

    /// Quick Look sizes itself to each new item a moment after loading it;
    /// put it back once that has happened, in case no notification caught it.
    private func settlePreview() {
        for delay in [0.05, 0.25] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.placePreview() }
        }
    }

    /// Catches Quick Look moving or resizing itself and puts it straight back.
    private func watchPreviewFrame(_ quickLook: QLPreviewPanel) {
        stopWatchingPreviewFrame()
        for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification] {
            previewObservers.append(NotificationCenter.default.addObserver(
                forName: name, object: quickLook, queue: nil) { [weak self] _ in self?.placePreview() })
        }
    }

    private func stopWatchingPreviewFrame() {
        previewObservers.forEach(NotificationCenter.default.removeObserver)
        previewObservers = []
    }

    private func closePreview() {
        guard isPreviewShown else { previewRequested = false; return }
        // The panel heads home while Quick Look fades, not after it.
        undockPreview()
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
        watchPreviewFrame(quickLook)
    }

    fileprivate func endPreview(_ quickLook: QLPreviewPanel) {
        debugLog("endPreview visible=\(quickLook.isVisible)")
        stopWatchingPreviewFrame()
        undockPreview()
        previewPanel = nil
        quickLook.dataSource = nil
        quickLook.delegate = nil
        previewedPath = nil
        previewPathOverride = nil
        previewContent.clear()
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

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewTarget == nil ? 0 : 1 }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard let path = previewTarget else { return nil }
        previewedPath = path
        switch previewContent.plan(for: path) {
        case .standIn(let url)?:
            return PreviewItem(url: url, title: (path as NSString).lastPathComponent)
        case .original?:
            return NSURL(fileURLWithPath: path)
        case nil:
            // Until the file has been looked at, Quick Look shows it as it
            // would anyway (its own view, or its notice for a file that is
            // gone or unreadable); a text stand-in replaces that once ready.
            previewContent.prepare(path) { [weak self] plan in
                guard let self, plan != .original, let previewPanel = self.previewPanel,
                      self.previewTarget == path else { return }
                previewPanel.reloadData()
            }
            return NSURL(fileURLWithPath: path)
        }
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
        // Docked, the preview simply appears in its place: a zoom from the
        // row would land in the middle of the screen first.
        // The same on the way out, while the panel is already sliding home.
        guard isVisible, !previewWasDocked, hits.indices.contains(row) else { return .zero }
        let rect = table.rect(ofRow: row)
        guard table.visibleRect.intersects(rect) else { return .zero }
        return self.panel.convertToScreen(table.convert(rect, to: nil))
    }

    /// Test hook: previews `path` as if its row were selected, until the
    /// selection moves.
    func previewPathForTesting(_ path: String) {
        guard isVisible else { return }
        previewPathOverride = path
        if let previewPanel { previewPanel.reloadData(); placePreview(); settlePreview() } else { showPreview() }
    }

    /// Removes every stand-in before the application quits.
    func removePreviewStandIns() { previewContent.clearNow() }

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

/// A short message on a dark capsule, over the bottom of the panel.
private final class NoticeView: NSView {
    private let label = NSTextField(labelWithString: "")
    override var wantsUpdateLayer: Bool { true }

    var text: String {
        get { label.stringValue }
        set { label.stringValue = newValue; invalidateIntrinsicContentSize() }
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 13
        layer?.cornerCurve = .continuous
        label.font = .systemFont(ofSize: 12.5, weight: .medium)
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
    }
}
