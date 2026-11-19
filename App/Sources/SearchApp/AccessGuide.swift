import AppKit

/// Detects Full Disk Access and walks the user through granting it.
enum DiskAccess {
    /// The privacy database is readable only with Full Disk Access, so an
    /// open attempt tells the two states apart without touching user files.
    static var isGranted: Bool {
        let path = NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db"
        let descriptor = open(path, O_RDONLY)
        guard descriptor >= 0 else { return false }
        close(descriptor)
        return true
    }

    static func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}

final class AccessGuideController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var poll: Timer?
    private let statusLabel = NSTextField(labelWithString: "")
    private let statusDot = NSImageView()
    private let primary = NSButton(title: "打开系统设置", target: nil, action: nil)
    private let onGranted: () -> Void
    private var reported = false

    init(onGranted: @escaping () -> Void) {
        self.onGranted = onGranted
    }

    func show() {
        if window == nil { build() }
        refresh()
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        poll?.invalidate()
        poll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func windowWillClose(_ notification: Notification) {
        poll?.invalidate()
        poll = nil
    }

    private func build() {
        let size = NSSize(width: 460, height: 318)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.delegate = self

        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown

        let title = NSTextField(labelWithString: "让搜索覆盖整台电脑")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        title.alignment = .center

        let body = NSTextField(wrappingLabelWithString:
            "不授权也能用，但邮件、信息等受系统保护的位置搜不到。\n只读取文件名、大小和修改时间，不读内容，不联网。")
        body.font = .systemFont(ofSize: 13)
        body.textColor = .secondaryLabelColor
        body.alignment = .center

        let steps = NSTextField(wrappingLabelWithString:
            "在“完整磁盘访问权限”列表里打开“文件搜索预览”的开关。\n列表里没有时，点下方的“＋”，从“应用程序”里添加。")
        steps.font = .systemFont(ofSize: 12)
        steps.textColor = .tertiaryLabelColor
        steps.alignment = .center

        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        statusDot.imageScaling = .scaleProportionallyDown
        let status = NSStackView(views: [statusDot, statusLabel])
        status.spacing = 5

        primary.target = self
        primary.action = #selector(primaryAction)
        primary.keyEquivalent = "\r"
        primary.controlSize = .large
        primary.bezelStyle = .rounded
        let later = NSButton(title: "暂不授权", target: self, action: #selector(decline))
        later.controlSize = .large
        later.bezelStyle = .rounded
        let buttons = NSStackView(views: [later, primary])
        buttons.spacing = 10

        let stack = NSStackView(views: [icon, title, body, steps, status, buttons])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.setCustomSpacing(8, after: icon)
        stack.setCustomSpacing(16, after: steps)
        stack.setCustomSpacing(18, after: status)
        stack.edgeInsets = NSEdgeInsets(top: 34, left: 40, bottom: 24, right: 40)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView(frame: NSRect(origin: .zero, size: size))
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            icon.widthAnchor.constraint(equalToConstant: 64),
            icon.heightAnchor.constraint(equalToConstant: 64),
            body.widthAnchor.constraint(equalToConstant: 380),
            steps.widthAnchor.constraint(equalToConstant: 380),
        ])
        window.contentView = content
        self.window = window
    }

    private func refresh() {
        let granted = DiskAccess.isGranted
        statusLabel.stringValue = granted ? "已授权，正在补充之前读不到的位置" : "尚未授权"
        statusLabel.textColor = granted ? .labelColor : .secondaryLabelColor
        let name = granted ? "checkmark.circle.fill" : "circle.dashed"
        statusDot.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        statusDot.contentTintColor = granted ? .systemGreen : .tertiaryLabelColor
        primary.title = granted ? "完成" : "打开系统设置"
        if granted && !reported {
            reported = true
            onGranted()
        }
    }

    @objc private func primaryAction() {
        if DiskAccess.isGranted { closeWindow() } else { DiskAccess.openSystemSettings() }
    }

    /// Declining is remembered: the guide never opens by itself again, so
    /// say where the switch lives before closing.
    @objc private func decline() {
        guard !DiskAccess.isGranted, let window else { closeWindow(); return }
        let alert = NSAlert()
        alert.messageText = "好的，不会再主动询问"
        alert.informativeText = "以后想开启时：右键点菜单栏的搜索图标，选“设置…”，在“搜索范围”里点“前往授权…”。"
        alert.addButton(withTitle: "知道了")
        alert.beginSheetModal(for: window) { [weak self] _ in self?.closeWindow() }
    }

    @objc private func closeWindow() { window?.close() }
}
