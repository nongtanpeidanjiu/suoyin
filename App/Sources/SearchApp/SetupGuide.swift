import AppKit
import ServiceManagement

/// The setup guide shown on the first launch: five steps in one window of
/// fixed size. Every choice takes effect and is saved at once; closing the
/// window at any step keeps the defaults for the steps not seen.
final class SetupGuideController: NSObject, NSWindowDelegate {
    enum Step: Int, CaseIterable {
        case welcome, access, volumes, shortcut, done
    }

    private static let size = NSSize(width: 540, height: 520)
    private static let bodyWidth: CGFloat = 420

    private let service: SearchService
    private let shortcuts: ShortcutCenter
    private let onGranted: () -> Void
    private let onFinish: () -> Void
    private var window: NSWindow?
    private var step: Step = .welcome
    private var pages: [Step: NSView] = [:]
    private let stage = NSView()
    private let dots = StepDots(count: Step.allCases.count)
    private let back = NSButton(title: "上一步", target: nil, action: nil)
    private let next = NSButton(title: "下一步", target: nil, action: nil)
    private var poll: Timer?
    private var reportedGrant = false

    // Access step.
    private let accessBody = NSTextField(wrappingLabelWithString: "")
    private let accessIcon = NSImageView()
    private let accessLabel = NSTextField(labelWithString: "")
    private let accessSteps = NSTextField(wrappingLabelWithString: "")
    private let openSettings = NSButton(title: "打开系统设置", target: nil, action: nil)
    private let accessLater = NSTextField(wrappingLabelWithString: "")

    // Volumes step.
    private let leaveOut = NSButton(radioButtonWithTitle: "不自动加入，需要时在设置里手动加入", target: nil, action: nil)
    private let addNew = NSButton(radioButtonWithTitle: "自动加入新插入的外接磁盘", target: nil, action: nil)
    private let attachedHeading = NSTextField(labelWithString: "当前接入的外接磁盘：")
    private let attachedList = ExternalVolumeList(width: SetupGuideController.bodyWidth, maxRows: 2, emptyText: "")
    private let volumesError = NSTextField(wrappingLabelWithString: "")

    // Shortcut step.
    private let recorder = ShortcutRecorder(name: ShortcutRole.global.title, shortcut: ShortcutRole.global.standard)
    private let restore = NSButton(title: "恢复默认", target: nil, action: nil)
    private let shortcutMessage = NSTextField(wrappingLabelWithString: "")
    private var shortcutFailure: String?
    private let login = NSButton(checkboxWithTitle: "登录时启动", target: nil, action: nil)
    private let loginMessage = NSTextField(wrappingLabelWithString: "")
    private var loginFailure: String?
    private var shortcutMessageRow: NSGridRow?
    private var loginMessageRow: NSGridRow?

    // Last step.
    private let doneBody = NSTextField(wrappingLabelWithString: "")

    init(service: SearchService, shortcuts: ShortcutCenter, onGranted: @escaping () -> Void,
         onFinish: @escaping () -> Void) {
        self.service = service
        self.shortcuts = shortcuts
        self.onGranted = onGranted
        self.onFinish = onFinish
    }

    var isVisible: Bool { window?.isVisible == true }

    /// Opens the guide at `step`, or moves an open guide there.
    func show(at step: Step = .welcome) {
        if window == nil { build() }
        go(to: step, animated: isVisible)
        NSApp.activate(ignoringOtherApps: true)
        if !isVisible { window?.center() }
        window?.makeKeyAndOrderFront(nil)
        poll?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer, forMode: .common)
        poll = timer
    }

    func windowWillClose(_ notification: Notification) {
        poll?.invalidate()
        poll = nil
        if recorder.isRecording { window?.makeFirstResponder(nil) }
    }

    /// The attached volumes changed; the list on the volumes step follows.
    func volumesChanged() {
        guard isVisible else { return }
        refreshVolumes()
    }

    // MARK: Building

    private func build() {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.size),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "设置向导"
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace]
        window.delegate = self

        back.target = self
        back.action = #selector(goBack)
        next.target = self
        next.action = #selector(goNext)
        for button in [back, next] {
            button.bezelStyle = .rounded
            button.controlSize = .large
        }
        stage.translatesAutoresizingMaskIntoConstraints = false
        dots.translatesAutoresizingMaskIntoConstraints = false
        back.translatesAutoresizingMaskIntoConstraints = false
        next.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView(frame: NSRect(origin: .zero, size: Self.size))
        for view in [stage, dots, back, next] { content.addSubview(view) }
        NSLayoutConstraint.activate([
            stage.topAnchor.constraint(equalTo: content.topAnchor),
            stage.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stage.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stage.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -64),
            back.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            back.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            next.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            next.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            next.widthAnchor.constraint(greaterThanOrEqualToConstant: 96),
            back.widthAnchor.constraint(greaterThanOrEqualToConstant: 96),
            dots.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            dots.centerYAnchor.constraint(equalTo: next.centerYAnchor),
        ])
        window.contentView = content
        self.window = window

        pages = [
            .welcome: welcomePage(),
            .access: accessPage(),
            .volumes: volumesPage(),
            .shortcut: shortcutPage(),
            .done: donePage(),
        ]
    }

    /// The top of every step: a symbol or the application icon, a title and
    /// a short explanation, centred.
    private func page(icon: NSImage?, symbol: String?, title: String, body: String, bodyField: NSTextField? = nil,
                      below: [NSView]) -> NSView {
        let image = NSImageView()
        if let icon {
            image.image = icon
            image.imageScaling = .scaleProportionallyUpOrDown
        } else if let symbol {
            image.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            image.symbolConfiguration = .init(pointSize: 40, weight: .light)
            image.contentTintColor = .controlAccentColor
        }
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 20, weight: .semibold)
        heading.alignment = .center
        let text = bodyField ?? NSTextField(wrappingLabelWithString: "")
        text.stringValue = body
        text.font = .systemFont(ofSize: 13)
        text.textColor = .secondaryLabelColor
        text.alignment = .center
        text.isSelectable = false

        let stack = NSStackView(views: [image, heading, text] + below)
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.setCustomSpacing(10, after: image)
        stack.setCustomSpacing(8, after: heading)
        stack.setCustomSpacing(22, after: text)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let view = NSView()
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 40),
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            image.widthAnchor.constraint(equalToConstant: icon == nil ? 56 : 72),
            image.heightAnchor.constraint(equalToConstant: icon == nil ? 56 : 72),
            text.widthAnchor.constraint(equalToConstant: Self.bodyWidth),
        ])
        return view
    }

    private func smallNote(_ text: String, color: NSColor = .secondaryLabelColor,
                           width: CGFloat = SetupGuideController.bodyWidth) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.textColor = color
        field.isSelectable = false
        field.preferredMaxLayoutWidth = width
        field.widthAnchor.constraint(equalToConstant: width).isActive = true
        return field
    }

    private func welcomePage() -> NSView {
        let points = smallNote("接下来用几步完成设置。每一步的选择立即生效；\n随时可以关闭本窗口，以后在“设置”里也都能更改。",
                               color: .tertiaryLabelColor)
        points.alignment = .center
        return page(icon: NSApp.applicationIconImage, symbol: nil, title: "欢迎使用文件搜索",
                    body: "按文件名搜索整台电脑，输入几个字就能找到文件。\n只读取文件名、大小和修改时间，不读文件内容，不联网。",
                    below: [points])
    }

    private func accessPage() -> NSView {
        accessSteps.stringValue = "在“完整磁盘访问权限”列表里打开“文件搜索预览”的开关。\n列表里没有时，点下方的“＋”，从“应用程序”里添加。"
        accessSteps.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        accessSteps.textColor = .secondaryLabelColor
        accessSteps.alignment = .center
        accessSteps.isSelectable = false
        accessSteps.widthAnchor.constraint(equalToConstant: Self.bodyWidth).isActive = true

        accessIcon.symbolConfiguration = .init(pointSize: 13, weight: .regular)
        accessLabel.font = .systemFont(ofSize: 13, weight: .medium)
        let status = NSStackView(views: [accessIcon, accessLabel])
        status.spacing = 5

        openSettings.target = self
        openSettings.action = #selector(openAccessSettings)
        openSettings.bezelStyle = .rounded
        openSettings.controlSize = .large

        accessLater.stringValue = "也可以先跳过。以后想开启时：右键点按菜单栏中的搜索图标，\n选“设置…”，在“搜索范围”里点“前往授权…”。"
        accessLater.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        accessLater.textColor = .tertiaryLabelColor
        accessLater.alignment = .center
        accessLater.isSelectable = false
        accessLater.widthAnchor.constraint(equalToConstant: Self.bodyWidth).isActive = true

        let view = page(icon: nil, symbol: "lock.shield", title: "让搜索覆盖整台电脑", body: "",
                        bodyField: accessBody, below: [accessSteps, status, openSettings, accessLater])
        if let stack = view.subviews.first as? NSStackView {
            stack.setCustomSpacing(16, after: accessSteps)
            stack.setCustomSpacing(16, after: status)
            stack.setCustomSpacing(18, after: openSettings)
        }
        return view
    }

    private func volumesPage() -> NSView {
        leaveOut.target = self
        leaveOut.action = #selector(chooseVolumes(_:))
        addNew.target = self
        addNew.action = #selector(chooseVolumes(_:))
        let leaveOutNote = smallNote("插入时不扫描，不额外占用磁盘和电量。\n想搜某块磁盘时，在“设置 › 搜索范围”里打开它的开关。",
                                     width: Self.bodyWidth - 20)
        let addNewNote = smallNote("插上就能搜到上面的文件。\n大容量机械硬盘首次扫描可能需要几十分钟，期间仍可正常搜索。",
                                   width: Self.bodyWidth - 20)
        func option(_ button: NSButton, _ note: NSTextField) -> NSStackView {
            let stack = NSStackView(views: [button, note])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 3
            stack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
            note.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 20).isActive = true
            return stack
        }
        attachedHeading.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        attachedHeading.textColor = .secondaryLabelColor
        attachedList.onToggle = { [weak self] id, included in
            self?.service.setExternalVolume(id, included: included)
            self?.refreshVolumes()
        }
        volumesError.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        volumesError.textColor = .systemRed
        volumesError.preferredMaxLayoutWidth = Self.bodyWidth
        volumesError.isHidden = true

        let options = NSStackView(views: [option(leaveOut, leaveOutNote), option(addNew, addNewNote),
                                          attachedHeading, attachedList, volumesError])
        options.orientation = .vertical
        options.alignment = .leading
        options.spacing = 12
        options.setCustomSpacing(16, after: options.arrangedSubviews[1])
        options.setCustomSpacing(6, after: attachedHeading)
        options.setCustomSpacing(8, after: attachedList)
        options.widthAnchor.constraint(equalToConstant: Self.bodyWidth).isActive = true
        return page(icon: nil, symbol: "externaldrive", title: "外接磁盘",
                    body: "插入移动硬盘或 U 盘时，要不要自动把它加入搜索？",
                    below: [options])
    }

    private func shortcutPage() -> NSView {
        recorder.onRecord = { [weak self] shortcut in self?.record(shortcut) }
        recorder.onRecordingChange = { [weak self] recording in
            guard let self else { return }
            if recording {
                // The current shortcut must reach the recorder, to be recorded or refused.
                self.shortcuts.suspendGlobal()
                self.shortcutFailure = nil
            } else {
                self.shortcuts.resumeGlobal()
            }
            self.refreshShortcut()
        }
        restore.target = self
        restore.action = #selector(restoreShortcut)
        restore.setAccessibilityLabel("将全局快捷键恢复默认")
        login.target = self
        login.action = #selector(toggleLogin)

        let grid = NSGridView()
        grid.rowSpacing = 6
        grid.columnSpacing = 10
        grid.rowAlignment = .firstBaseline
        func label(_ text: String) -> NSTextField {
            let field = NSTextField(labelWithString: text)
            field.alignment = .right
            return field
        }
        let controls = NSStackView(views: [recorder, restore])
        controls.spacing = 8
        controls.alignment = .firstBaseline
        grid.addRow(with: [label("全局快捷键："), controls])
        grid.addRow(with: [NSGridCell.emptyContentView, smallNote("在任何地方按下都可以打开或收起搜索。\n点按框后按下新组合，按 Esc 取消。",
                                                                  width: 280)])
        for field in [shortcutMessage, loginMessage] {
            field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            field.isSelectable = false
            field.preferredMaxLayoutWidth = 280
            field.widthAnchor.constraint(equalToConstant: 280).isActive = true
        }
        shortcutMessageRow = grid.addRow(with: [NSGridCell.emptyContentView, shortcutMessage])
        grid.addRow(with: [label("启动："), login]).topPadding = 14
        grid.addRow(with: [NSGridCell.emptyContentView, smallNote("登录电脑后自动在菜单栏待命，随时可以搜索。", width: 280)])
        loginMessageRow = grid.addRow(with: [NSGridCell.emptyContentView, loginMessage])
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .leading
        return page(icon: nil, symbol: "keyboard", title: "快捷键与启动",
                    body: "用一组快捷键随时打开搜索。以后可以在“设置 › 通用”里更改。",
                    below: [grid])
    }

    private func donePage() -> NSView {
        let tips = smallNote("在搜索结果里：回车打开文件，⌘回车 在访达中显示，⌘C 复制完整路径。\n以后想改设置：右键点按菜单栏中的搜索图标，选“设置…”。",
                             color: .tertiaryLabelColor)
        tips.alignment = .center
        return page(icon: nil, symbol: "checkmark.circle", title: "设置完成", body: "",
                    bodyField: doneBody, below: [tips])
    }

    // MARK: Moving between steps

    private func go(to target: Step, animated: Bool) {
        guard let page = pages[target] else { return }
        step = target
        refresh()
        // Every other page goes, including one still fading out from a
        // quick earlier click, so two pages never stay on top of each other.
        let leaving = stage.subviews.filter { $0 !== page }
        if page.superview !== stage {
            page.translatesAutoresizingMaskIntoConstraints = false
            stage.addSubview(page)
            NSLayoutConstraint.activate([
                page.topAnchor.constraint(equalTo: stage.topAnchor),
                page.bottomAnchor.constraint(equalTo: stage.bottomAnchor),
                page.leadingAnchor.constraint(equalTo: stage.leadingAnchor),
                page.trailingAnchor.constraint(equalTo: stage.trailingAnchor),
            ])
            page.alphaValue = 0
        }
        // A short cross-fade in place; none with Reduce Motion.
        if animated && !Motion.reduced && !leaving.isEmpty {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.15
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                page.animator().alphaValue = 1
                for view in leaving { view.animator().alphaValue = 0 }
            }, completionHandler: { [weak self] in
                // Only pages that are still not the current one are removed.
                for view in leaving where view !== self?.pages[self?.step ?? target] { view.removeFromSuperview() }
            })
        } else {
            leaving.forEach { $0.removeFromSuperview() }
            page.alphaValue = 1
        }
        window?.makeFirstResponder(nil)
        window?.recalculateKeyViewLoop()
    }

    @objc private func goBack() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        go(to: previous, animated: true)
    }

    @objc private func goNext() {
        guard let following = Step(rawValue: step.rawValue + 1) else {
            window?.close()
            onFinish()
            return
        }
        go(to: following, animated: true)
    }

    // MARK: State

    /// Brings the visible step and the buttons up to date; also run every
    /// second while the window is open, for the permission and login item.
    private func refresh() {
        let granted = DiskAccess.isGranted
        if granted && !reportedGrant {
            reportedGrant = true
            onGranted()
        }
        dots.current = step.rawValue
        back.isHidden = step == .welcome
        switch step {
        case .welcome: next.title = "开始设置"
        case .access: next.title = granted ? "下一步" : "暂不授权"
        case .done: next.title = "开始使用"
        default: next.title = "下一步"
        }
        // Return opens System Settings while access is missing on that step.
        let settingsIsDefault = step == .access && !granted
        next.keyEquivalent = settingsIsDefault ? "" : "\r"
        openSettings.keyEquivalent = settingsIsDefault ? "\r" : ""

        switch step {
        case .access: refreshAccess(granted)
        case .volumes: refreshVolumes()
        case .shortcut: refreshShortcut(); reloadLoginItem()
        case .done: refreshDone()
        case .welcome: break
        }
    }

    private func refreshAccess(_ granted: Bool) {
        accessBody.stringValue = granted
            ? "已经授权，邮件、信息等受系统保护的位置也能搜到。"
            : "授权后，邮件、信息等受系统保护的位置也能搜到。\n不授权也能用，只是这些位置搜不到。"
        accessLabel.stringValue = granted ? "已授权" : "尚未授权"
        accessLabel.textColor = granted ? .labelColor : .secondaryLabelColor
        accessIcon.image = NSImage(systemSymbolName: granted ? "checkmark.circle.fill" : "circle.dashed",
                                   accessibilityDescription: nil)
        accessIcon.contentTintColor = granted ? .systemGreen : .tertiaryLabelColor
        accessSteps.isHidden = granted
        openSettings.isHidden = granted
        accessLater.isHidden = granted
    }

    private func refreshVolumes() {
        let addsNew = service.includesNewExternalVolumes
        leaveOut.state = addsNew ? .off : .on
        addNew.state = addsNew ? .on : .off
        let attached = service.externalVolumes.filter(\.isOnline)
        attachedHeading.isHidden = attached.isEmpty
        attachedList.isHidden = attached.isEmpty
        attachedList.show(attached)
        let error = service.externalVolumeSettingsError.map(externalVolumeErrorText)
        volumesError.stringValue = error ?? ""
        volumesError.isHidden = error == nil
    }

    private func refreshShortcut() {
        let current = shortcuts.current(.global)
        if !recorder.isRecording { recorder.shortcut = current }
        restore.isEnabled = current != ShortcutRole.global.standard
        if recorder.isRecording {
            show(shortcutMessage, "按下后没有反应，说明这组键已被系统占用。", warning: false)
        } else if let failure = shortcutFailure {
            show(shortcutMessage, failure, warning: true)
        } else if shortcuts.registeredGlobal == nil {
            show(shortcutMessage, "\(current.display) 已被其他应用占用，全局快捷键目前不可用，请换一组。", warning: true)
        } else {
            show(shortcutMessage, nil, warning: false)
        }
    }

    private func show(_ field: NSTextField, _ text: String?, warning: Bool) {
        field.stringValue = text ?? ""
        field.textColor = warning ? .systemRed : .secondaryLabelColor
        // The whole grid row goes, so a hidden message leaves no gap.
        let row = field === shortcutMessage ? shortcutMessageRow : field === loginMessage ? loginMessageRow : nil
        if let row { row.isHidden = text == nil } else { field.isHidden = text == nil }
    }

    private func refreshDone() {
        if let global = shortcuts.registeredGlobal {
            doneBody.stringValue = "按 \(global.display) 随时打开搜索，再按一次收起。\n也可以点按菜单栏中的放大镜图标。"
        } else {
            doneBody.stringValue = "点按菜单栏中的放大镜图标打开搜索。\n全局快捷键目前不可用，可以在“设置 › 通用”里换一组。"
        }
    }

    // MARK: Actions

    @objc private func openAccessSettings() { DiskAccess.openSystemSettings() }

    @objc private func chooseVolumes(_ sender: NSButton) {
        service.includesNewExternalVolumes = sender === addNew
        refreshVolumes()
    }

    private func record(_ shortcut: Shortcut) {
        if let problem = shortcuts.change(.global, to: shortcut) {
            shortcuts.resumeGlobal()
            shortcutFailure = problem.refusal(for: shortcut)
        } else {
            shortcutFailure = nil
        }
        refreshShortcut()
    }

    @objc private func restoreShortcut() {
        if recorder.isRecording { window?.makeFirstResponder(nil) }
        record(ShortcutRole.global.standard)
    }

    /// The box always shows what the system has actually registered.
    private func reloadLoginItem() {
        let status = SMAppService.mainApp.status
        login.state = status == .enabled || status == .requiresApproval ? .on : .off
        if let loginFailure {
            show(loginMessage, loginFailure, warning: true)
        } else if status == .requiresApproval {
            show(loginMessage, "需要在系统设置的“登录项”里允许本应用。", warning: false)
        } else {
            show(loginMessage, nil, warning: false)
        }
    }

    @objc private func toggleLogin() {
        let wanted = login.state == .on
        do {
            if wanted { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginFailure = nil
        } catch {
            let action = wanted ? "无法设为登录时启动" : "无法取消登录时启动"
            loginFailure = "\(action)：\(error.localizedDescription)"
        }
        reloadLoginItem()
    }
}

/// Small dots under the steps, the current one filled darker.
private final class StepDots: NSView {
    private let count: Int
    var current = 0 {
        didSet {
            needsDisplay = true
            setAccessibilityValue("第 \(current + 1) 步，共 \(count) 步")
        }
    }
    private static let diameter: CGFloat = 7
    private static let gap: CGFloat = 9

    init(count: Int) {
        self.count = count
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("步骤")
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: CGFloat(count) * Self.diameter + CGFloat(count - 1) * Self.gap, height: Self.diameter)
    }

    override func draw(_ dirtyRect: NSRect) {
        for index in 0..<count {
            let rect = NSRect(x: CGFloat(index) * (Self.diameter + Self.gap), y: 0,
                              width: Self.diameter, height: Self.diameter)
            (index == current ? NSColor.labelColor.withAlphaComponent(0.7) : NSColor.tertiaryLabelColor).setFill()
            NSBezierPath(ovalIn: rect).fill()
        }
    }
}
