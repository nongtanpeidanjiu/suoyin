import Carbon.HIToolbox

/// System-wide shortcut registered through the Carbon hot key service, which
/// needs no accessibility or input-monitoring permission.
final class HotKey {
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private static var actions: [UInt32: () -> Void] = [:]
    private let identifier: UInt32

    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        identifier = UInt32(HotKey.actions.count + 1)
        HotKey.actions[identifier] = action

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var pressed = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &pressed)
            HotKey.actions[pressed.id]?()
            return noErr
        }, 1, &spec, nil, &handler)
        guard installed == noErr else { return nil }

        let id = EventHotKeyID(signature: OSType(0x4653_4831), id: identifier)
        let status = RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &reference)
        guard status == noErr else { return nil }
    }

    deinit {
        if let reference { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
        HotKey.actions[identifier] = nil
    }

    /// Option + Shift + Space.
    static func defaultShortcut(action: @escaping () -> Void) -> HotKey? {
        HotKey(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey | shiftKey), action: action)
    }
}
