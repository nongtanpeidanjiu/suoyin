import AppKit

/// `--backdrop light|dark`：截图用的全屏背景。
///
/// 每块屏幕铺一个窗口，层级在桌面图标之上、普通窗口之下，不接收点按、不能
/// 成为主窗口、不出现在程序坞、窗口菜单和窗口切换里。内容是代码画的柔和
/// 渐变加几团色斑，面板的玻璃有东西可折射，又不会露出桌面上的图标。窗口
/// 随进程退出消失。
final class Backdrop {
    private var windows: [NSWindow] = []
    private let dark: Bool
    private var observer: NSObjectProtocol?

    init(dark: Bool) {
        self.dark = dark
        cover()
        // 接上或拔掉显示器、改分辨率后重新铺。
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.cover() }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    private func cover() {
        windows.forEach { $0.orderOut(nil) }
        windows = NSScreen.screens.map { screen in
            let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.setFrame(screen.frame, display: false)
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            window.isExcludedFromWindowsMenu = true
            window.ignoresMouseEvents = true
            window.isReleasedWhenClosed = false
            window.hasShadow = false
            window.isOpaque = true
            window.backgroundColor = dark ? .black : .white
            window.contentView = BackdropView(dark: dark)
            window.orderFront(nil)
            return window
        }
    }
}

private final class BackdropView: NSView {
    private let dark: Bool

    init(dark: Bool) {
        self.dark = dark
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
            CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
        }
        let size = bounds.size

        // 底色：从左上到右下的斜向渐变。
        let base = dark ? [color(0x232B3A), color(0x0A0C11)] : [color(0xFBF6EF), color(0xD9E1EB)]
        if let gradient = CGGradient(colorsSpace: space, colors: base as CFArray, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size.height), end: CGPoint(x: size.width, y: 0),
                                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }

        // 几团柔和的色斑，位置按屏幕比例给出（x, y, 半径占较长边的比例）。
        let blobs: [(CGFloat, CGFloat, CGFloat, UInt32, CGFloat)] = dark
            ? [(0.22, 0.70, 0.42, 0x3A5A8C, 0.55), (0.78, 0.30, 0.38, 0x5B3F7A, 0.45),
               (0.60, 0.85, 0.30, 0x2F6F78, 0.35), (0.10, 0.15, 0.28, 0x4A3550, 0.30)]
            : [(0.20, 0.75, 0.40, 0xF6D5C3, 0.70), (0.80, 0.28, 0.42, 0xC7D7F0, 0.75),
               (0.62, 0.86, 0.30, 0xE3D8F2, 0.60), (0.12, 0.18, 0.30, 0xD6ECE6, 0.55)]
        let longer = max(size.width, size.height)
        for (x, y, radius, hex, alpha) in blobs {
            let center = CGPoint(x: x * size.width, y: y * size.height)
            let colors = [color(hex, alpha), color(hex, 0)] as CFArray
            guard let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) else { continue }
            context.drawRadialGradient(gradient, startCenter: center, startRadius: 0,
                                       endCenter: center, endRadius: radius * longer, options: [])
        }
    }
}
