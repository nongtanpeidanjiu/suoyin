import AppKit
import Carbon.HIToolbox

/// A field showing a shortcut. Click it, then press a new key combination;
/// Esc cancels. Used for every shortcut row in the settings window.
final class ShortcutRecorder: NSControl {
    var shortcut: Shortcut { didSet { refresh() } }
    /// Called with the combination the user pressed; the owner decides whether it is accepted.
    var onRecord: ((Shortcut) -> Void)?
    var onRecordingChange: ((Bool) -> Void)?
    private(set) var isRecording = false
    private let face = NSTextField(string: "")
    private var liveModifiers: NSEvent.ModifierFlags = []

    init(name: String, shortcut: Shortcut) {
        self.shortcut = shortcut
        super.init(frame: .zero)
        face.isEditable = false
        face.isSelectable = false
        face.isBezeled = true
        face.bezelStyle = .roundedBezel
        face.alignment = .center
        face.font = .systemFont(ofSize: 13)
        face.refusesFirstResponder = true
        face.translatesAutoresizingMaskIntoConstraints = false
        addSubview(face)
        NSLayoutConstraint.activate([
            face.leadingAnchor.constraint(equalTo: leadingAnchor),
            face.trailingAnchor.constraint(equalTo: trailingAnchor),
            face.topAnchor.constraint(equalTo: topAnchor),
            face.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(equalToConstant: 150),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(name)
        setAccessibilityHelp("按下后输入新的组合键，按 Esc 取消")
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    override var firstBaselineOffsetFromTop: CGFloat { face.firstBaselineOffsetFromTop }

    override func mouseDown(with event: NSEvent) {
        isRecording ? stop() : start()
    }

    override func accessibilityPerformPress() -> Bool {
        isRecording ? stop() : start()
        return true
    }

    override func keyDown(with event: NSEvent) {
        if isRecording { capture(event) }
        else if event.keyCode == UInt16(kVK_Space) || event.keyCode == UInt16(kVK_Return) { start() }
        else { super.keyDown(with: event) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording, window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        capture(event)
        return true
    }

    override func flagsChanged(with event: NSEvent) {
        guard isRecording else { return super.flagsChanged(with: event) }
        liveModifiers = event.modifierFlags.intersection([.control, .option, .shift, .command])
        refresh()
    }

    override func resignFirstResponder() -> Bool {
        if isRecording { stop() }
        return super.resignFirstResponder()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil, isRecording { stop() }
    }

    private func capture(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection([.control, .option, .shift, .command])
        if event.keyCode == UInt16(kVK_Escape), flags.isEmpty { stop(); return }
        let pressed = Shortcut(event: event)
        stop()
        onRecord?(pressed)
    }

    private func start() {
        guard !isRecording else { return }
        window?.makeFirstResponder(self)
        isRecording = true
        liveModifiers = []
        onRecordingChange?(true)
        refresh()
    }

    private func stop() {
        guard isRecording else { return }
        isRecording = false
        liveModifiers = []
        onRecordingChange?(false)
        refresh()
    }

    private func refresh() {
        if isRecording {
            var held = ""
            if liveModifiers.contains(.control) { held += "⌃" }
            if liveModifiers.contains(.option) { held += "⌥" }
            if liveModifiers.contains(.shift) { held += "⇧" }
            if liveModifiers.contains(.command) { held += "⌘" }
            face.stringValue = held.isEmpty ? "请按下快捷键" : held
            face.textColor = .secondaryLabelColor
        } else {
            face.stringValue = shortcut.display
            face.textColor = .labelColor
        }
        setAccessibilityValue(isRecording ? "正在录入" : shortcut.spoken)
        noteFocusRingMaskChanged()
        needsDisplay = true
    }

    // The system focus ring marks the recording state.
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() {
        guard isRecording else { return }
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }
}
