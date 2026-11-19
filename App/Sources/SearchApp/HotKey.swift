import AppKit
import Carbon.HIToolbox

/// A key plus Carbon modifier flags, as the hot key service expects them.
struct Shortcut: Equatable {
    var keyCode: UInt32
    var modifiers: UInt32

    static let relevantModifiers = UInt32(controlKey | optionKey | shiftKey | cmdKey)

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    init(event: NSEvent) {
        self.init(keyCode: UInt32(event.keyCode), modifiers: Self.modifiers(of: event))
    }

    /// Control, Option, Shift and Command of a key event as Carbon flags;
    /// Caps Lock, Fn and the keypad flag are ignored.
    static func modifiers(of event: NSEvent) -> UInt32 {
        let flags = event.modifierFlags
        var carbon: UInt32 = 0
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        return carbon
    }

    func matches(_ event: NSEvent) -> Bool {
        UInt32(event.keyCode) == keyCode && Self.modifiers(of: event) == modifiers
    }

    static func symbols(_ modifiers: UInt32) -> String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text
    }

    /// Symbols in the system's order, for example "⌥⇧空格".
    var display: String { Self.symbols(modifiers) + Self.keyName(keyCode) }

    /// Spoken form for VoiceOver, for example "Option Shift 空格".
    var spoken: String {
        var parts: [String] = []
        if modifiers & UInt32(controlKey) != 0 { parts.append("Control") }
        if modifiers & UInt32(optionKey) != 0 { parts.append("Option") }
        if modifiers & UInt32(shiftKey) != 0 { parts.append("Shift") }
        if modifiers & UInt32(cmdKey) != 0 { parts.append("Command") }
        return (parts + [Self.keyName(keyCode)]).joined(separator: " ")
    }

    /// The key equivalent a menu item shows for this combination.
    var menuKeyEquivalent: (key: String, modifiers: NSEvent.ModifierFlags)? {
        let key: String
        if let special = Self.menuKeys[Int(keyCode)] {
            key = String(Character(UnicodeScalar(special)!))
        } else if let character = Self.layoutCharacter(keyCode) {
            key = character
        } else {
            return nil
        }
        var flags: NSEvent.ModifierFlags = []
        if modifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if modifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if modifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if modifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        return (key, flags)
    }

    private static let menuKeys: [Int: Int] = [
        kVK_Space: 0x20, kVK_Return: 0x0D, kVK_ANSI_KeypadEnter: 0x03, kVK_Tab: 0x09, kVK_Delete: 0x08,
        kVK_Escape: 0x1B, kVK_ForwardDelete: NSDeleteFunctionKey, kVK_LeftArrow: NSLeftArrowFunctionKey,
        kVK_RightArrow: NSRightArrowFunctionKey, kVK_UpArrow: NSUpArrowFunctionKey,
        kVK_DownArrow: NSDownArrowFunctionKey, kVK_Home: NSHomeFunctionKey, kVK_End: NSEndFunctionKey,
        kVK_PageUp: NSPageUpFunctionKey, kVK_PageDown: NSPageDownFunctionKey,
        kVK_F1: NSF1FunctionKey, kVK_F2: NSF2FunctionKey, kVK_F3: NSF3FunctionKey, kVK_F4: NSF4FunctionKey,
        kVK_F5: NSF5FunctionKey, kVK_F6: NSF6FunctionKey, kVK_F7: NSF7FunctionKey, kVK_F8: NSF8FunctionKey,
        kVK_F9: NSF9FunctionKey, kVK_F10: NSF10FunctionKey, kVK_F11: NSF11FunctionKey, kVK_F12: NSF12FunctionKey,
    ]

    // MARK: Persistence

    private static func keys(_ role: ShortcutRole) -> (code: String, modifiers: String, changedAt: String) {
        switch role {
        // The names the first version used for the only shortcut it had.
        case .global: return ("hotKeyCode", "hotKeyModifiers", "hotKeyChangedAt")
        case .preview: return ("previewKeyCode", "previewKeyModifiers", "previewKeyChangedAt")
        }
    }

    static func stored(_ role: ShortcutRole) -> SavedShortcut {
        let defaults = UserDefaults.standard
        let names = keys(role)
        let changedAt = defaults.double(forKey: names.changedAt)
        guard defaults.object(forKey: names.code) != nil, defaults.object(forKey: names.modifiers) != nil
        else { return SavedShortcut(shortcut: nil, changedAt: changedAt) }
        let shortcut = Shortcut(keyCode: UInt32(defaults.integer(forKey: names.code)),
                                modifiers: UInt32(defaults.integer(forKey: names.modifiers)) & relevantModifiers)
        return SavedShortcut(shortcut: shortcut, changedAt: changedAt)
    }

    /// The default is stored as nothing, so a later version can change it.
    func save(as role: ShortcutRole) {
        let defaults = UserDefaults.standard
        let names = Self.keys(role)
        if self == role.standard {
            defaults.removeObject(forKey: names.code)
            defaults.removeObject(forKey: names.modifiers)
            defaults.removeObject(forKey: names.changedAt)
        } else {
            defaults.set(Int(keyCode), forKey: names.code)
            defaults.set(Int(modifiers), forKey: names.modifiers)
            defaults.set(Date().timeIntervalSince1970, forKey: names.changedAt)
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

    /// The lowercase character a key types on the current layout, or nil
    /// for keys that type none.
    static func layoutCharacter(_ code: UInt32) -> String? {
        guard specialKeys[Int(code)] == nil else { return nil }
        let name = keyName(code)
        return name == "?" ? nil : name.lowercased()
    }
}

/// The one system-wide shortcut, registered through the Carbon hot key
/// service, which needs no accessibility or input-monitoring permission.
/// The rules for which combinations are allowed live in ShortcutCenter.
final class HotKey {
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

    /// Switches to `new`. Fails when another application registered the
    /// combination first; the previous shortcut then stays registered.
    func register(_ new: Shortcut) -> Bool {
        if new == shortcut, reference != nil { return true }
        var created: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: serial + 1)
        let status = RegisterEventHotKey(new.keyCode, new.modifiers, id, GetApplicationEventTarget(), 0, &created)
        guard status == noErr, let created else { return false }
        if let reference { UnregisterEventHotKey(reference) }
        reference = created
        serial += 1
        shortcut = new
        return true
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
