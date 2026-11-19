import AppKit
import Carbon.HIToolbox

/// A key plus Carbon modifier flags, as the hot key service expects them.
struct Shortcut: Equatable {
    var keyCode: UInt32
    var modifiers: UInt32

    /// Option + Shift + Space.
    static let standard = Shortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey | shiftKey))

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    init(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var carbon: UInt32 = 0
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        self.init(keyCode: UInt32(event.keyCode), modifiers: carbon)
    }

    /// Shift alone would take over ordinary capital letters everywhere, so
    /// at least one of Control, Option and Command is required.
    var hasRequiredModifier: Bool {
        modifiers & UInt32(controlKey | optionKey | cmdKey) != 0
    }

    /// Symbols in the system's order, for example "⌥⇧空格".
    var display: String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + Self.keyName(keyCode)
    }

    /// Spoken form for VoiceOver, for example "Option Shift 空格".
    var spoken: String {
        var parts: [String] = []
        if modifiers & UInt32(controlKey) != 0 { parts.append("Control") }
        if modifiers & UInt32(optionKey) != 0 { parts.append("Option") }
        if modifiers & UInt32(shiftKey) != 0 { parts.append("Shift") }
        if modifiers & UInt32(cmdKey) != 0 { parts.append("Command") }
        return (parts + [Self.keyName(keyCode)]).joined(separator: " ")
    }

    // MARK: Persistence

    private static let codeKey = "hotKeyCode"
    private static let modifiersKey = "hotKeyModifiers"

    static var saved: Shortcut {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: codeKey) != nil, defaults.object(forKey: modifiersKey) != nil else { return .standard }
        let shortcut = Shortcut(keyCode: UInt32(defaults.integer(forKey: codeKey)),
                                modifiers: UInt32(defaults.integer(forKey: modifiersKey)))
        return shortcut.hasRequiredModifier ? shortcut : .standard
    }

    func save() {
        let defaults = UserDefaults.standard
        if self == .standard {
            defaults.removeObject(forKey: Self.codeKey)
            defaults.removeObject(forKey: Self.modifiersKey)
        } else {
            defaults.set(Int(keyCode), forKey: Self.codeKey)
            defaults.set(Int(modifiers), forKey: Self.modifiersKey)
        }
    }

    // MARK: Conflicts

    /// True when an enabled system shortcut (Spotlight, input source
    /// switching, screenshots…) already uses this combination. Registering
    /// such a combination succeeds but the system keeps the key press.
    var isTakenBySystem: Bool {
        var unmanaged: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&unmanaged) == noErr, let list = unmanaged?.takeRetainedValue() as? [[String: Any]]
        else { return false }
        let relevant = UInt32(controlKey | optionKey | shiftKey | cmdKey)
        return list.contains { entry in
            guard (entry[kHISymbolicHotKeyEnabled as String] as? Bool) == true,
                  let code = (entry[kHISymbolicHotKeyCode as String] as? NSNumber)?.uint32Value,
                  let flags = (entry[kHISymbolicHotKeyModifiers as String] as? NSNumber)?.uint32Value
            else { return false }
            return code == keyCode && flags & relevant == modifiers & relevant
        }
    }

    // MARK: Key names

    private static let specialKeys: [Int: String] = [
        kVK_Space: "空格", kVK_Return: "↩", kVK_ANSI_KeypadEnter: "⌤", kVK_Tab: "⇥", kVK_Delete: "⌫",
        kVK_ForwardDelete: "⌦", kVK_Escape: "⎋", kVK_LeftArrow: "←", kVK_RightArrow: "→",
        kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞",
        kVK_PageDown: "⇟", kVK_Help: "Help",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17",
        kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
    ]

    /// The character the key produces on the current keyboard layout.
    static func keyName(_ code: UInt32) -> String {
        if let name = specialKeys[Int(code)] { return name }
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "?" }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        var dead: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let status = data.withUnsafeBytes { raw -> OSStatus in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return -1 }
            return UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, characters.count, &length, &characters)
        }
        guard status == noErr, length > 0 else { return "?" }
        return String(utf16CodeUnits: characters, count: length).uppercased()
    }
}

/// The one system-wide shortcut, registered through the Carbon hot key
/// service, which needs no accessibility or input-monitoring permission.
final class HotKey {
    enum Failure: Error {
        case missingModifier
        case takenBySystem
        case taken
    }

    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var serial: UInt32 = 0
    private let action: () -> Void
    private(set) var shortcut: Shortcut?

    init(action: @escaping () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var pressed = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &pressed)
            let owner = Unmanaged<HotKey>.fromOpaque(context).takeUnretainedValue()
            guard pressed.signature == HotKey.signature, pressed.id == owner.serial else {
                return OSStatus(eventNotHandledErr)
            }
            owner.action()
            return noErr
        }, 1, &spec, context, &handler)
    }

    deinit {
        if let reference { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
    }

    private static let signature = OSType(0x4653_4831)

    /// Switches to `new`. On failure the previous shortcut stays registered.
    func register(_ new: Shortcut) -> Result<Void, Failure> {
        guard new.hasRequiredModifier else { return .failure(.missingModifier) }
        if new == shortcut, reference != nil { return .success(()) }
        if new.isTakenBySystem { return .failure(.takenBySystem) }
        var created: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: serial + 1)
        let status = RegisterEventHotKey(new.keyCode, new.modifiers, id, GetApplicationEventTarget(), 0, &created)
        guard status == noErr, let created else { return .failure(.taken) }
        if let reference { UnregisterEventHotKey(reference) }
        reference = created
        serial += 1
        shortcut = new
        return .success(())
    }

    /// Stops listening while a new shortcut is being recorded, so pressing
    /// the current one does not open the panel.
    func suspend() {
        if let reference { UnregisterEventHotKey(reference) }
        reference = nil
    }

    func resume() {
        guard reference == nil, let shortcut else { return }
        var created: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: serial)
        if RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, id, GetApplicationEventTarget(), 0, &created) == noErr {
            reference = created
        }
    }
}

extension HotKey.Failure {
    var message: String {
        switch self {
        case .missingModifier: return "快捷键需要包含 ⌃、⌥ 或 ⌘ 中的至少一个。"
        case .takenBySystem: return "这组按键已被系统快捷键占用，仍使用原来的快捷键。"
        case .taken: return "这组按键已被其他应用占用，仍使用原来的快捷键。"
        }
    }
}
