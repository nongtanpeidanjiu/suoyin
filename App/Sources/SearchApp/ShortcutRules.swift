import AppKit
import Carbon.HIToolbox

/// The two shortcuts the user can change.
enum ShortcutRole: CaseIterable {
    /// System-wide, registered with the Carbon hot key service.
    case global
    /// Local to the search panel: works only while the panel has key status.
    case preview

    /// The row title in the settings window.
    var title: String {
        switch self {
        case .global: return "全局快捷键"
        case .preview: return "预览文件"
        }
    }

    /// How a conflict message names this shortcut.
    var purpose: String {
        switch self {
        case .global: return "全局快捷键（打开或收起搜索）"
        case .preview: return "预览文件"
        }
    }

    var standard: Shortcut {
        switch self {
        case .global: return Shortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey | shiftKey))
        case .preview: return Shortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey))
        }
    }

    var other: ShortcutRole { self == .global ? .preview : .global }
}

// MARK: - Fixed keys

/// A key the panel or the text field already uses and the user cannot
/// change. This one table feeds both the conflict check and the panel's
/// key handling, so the two cannot drift apart.
struct FixedKey {
    enum Key: Equatable {
        /// A physical key, for keys that do not type a character.
        case code(Int)
        /// The character the key types on the current layout, the way the
        /// system matches menu key equivalents.
        case character(String)
    }

    /// What the panel itself does with the key. Keys without an action are
    /// handled by the search field's text system or the main menu; the
    /// arrows, Return, Tab and Esc reach the panel through the field.
    enum Action: Equatable {
        case reveal, copyPath, settings, quickLook
        case kind(SearchKind)
    }

    let key: Key
    let modifiers: UInt32
    let title: String
    let action: Action?

    init(_ key: Key, _ modifiers: Int = 0, _ title: String, _ action: Action? = nil) {
        self.key = key
        self.modifiers = UInt32(modifiers)
        self.title = title
        self.action = action
    }

    func matches(_ shortcut: Shortcut, character: (UInt32) -> String?) -> Bool {
        guard shortcut.modifiers & Shortcut.relevantModifiers == modifiers else { return false }
        switch key {
        case .code(let code): return shortcut.keyCode == UInt32(code)
        case .character(let text): return character(shortcut.keyCode) == text
        }
    }

    func matches(_ event: NSEvent) -> Bool {
        guard Shortcut.modifiers(of: event) == modifiers else { return false }
        switch key {
        case .code(let code): return Int(event.keyCode) == code
        case .character(let text): return event.charactersIgnoringModifiers?.lowercased() == text
        }
    }

    var display: String {
        switch key {
        case .code(let code): return Shortcut(keyCode: UInt32(code), modifiers: modifiers).display
        case .character(let text): return Shortcut.symbols(modifiers) + text.uppercased()
        }
    }
}

enum PanelKeys {
    private static let cmd = cmdKey, shift = shiftKey, opt = optionKey, ctrl = controlKey

    static let all: [FixedKey] = [
        // The search panel.
        FixedKey(.code(kVK_UpArrow), 0, "上移选中行"),
        FixedKey(.code(kVK_DownArrow), 0, "下移选中行"),
        FixedKey(.code(kVK_PageUp), 0, "向上翻页"),
        FixedKey(.code(kVK_PageDown), 0, "向下翻页"),
        FixedKey(.code(kVK_Return), 0, "打开"),
        FixedKey(.code(kVK_ANSI_KeypadEnter), 0, "打开"),
        FixedKey(.code(kVK_Return), cmd, "在访达中显示", .reveal),
        FixedKey(.code(kVK_ANSI_KeypadEnter), cmd, "在访达中显示", .reveal),
        FixedKey(.code(kVK_Tab), 0, "切换名称和路径"),
        FixedKey(.code(kVK_Tab), shift, "切换名称和路径"),
        FixedKey(.code(kVK_Escape), 0, "关闭预览、清空或收起"),
        FixedKey(.character("c"), cmd, "复制完整路径", .copyPath),
        FixedKey(.character(","), cmd, "设置", .settings),
        FixedKey(.character("y"), cmd, "快速查看（固定的备用键）", .quickLook),
    ] + kindKeys + [
        // Standard editing and window keys.
        FixedKey(.character("a"), cmd, "全选"),
        FixedKey(.character("x"), cmd, "剪切"),
        FixedKey(.character("v"), cmd, "粘贴"),
        FixedKey(.character("z"), cmd, "撤销"),
        FixedKey(.character("z"), cmd | shift, "重做"),
        FixedKey(.character("w"), cmd, "关闭窗口"),
        FixedKey(.character("m"), cmd, "最小化"),
        FixedKey(.character("h"), cmd, "隐藏"),
        FixedKey(.character("h"), cmd | opt, "隐藏其他"),
        FixedKey(.character("q"), cmd, "退出"),
        FixedKey(.character("."), cmd, "取消"),
        // Moving and selecting in the search field.
        FixedKey(.code(kVK_LeftArrow), cmd, "移到行首"),
        FixedKey(.code(kVK_RightArrow), cmd, "移到行尾"),
        FixedKey(.code(kVK_UpArrow), cmd, "移到开头"),
        FixedKey(.code(kVK_DownArrow), cmd, "移到结尾"),
        FixedKey(.code(kVK_LeftArrow), opt, "按词左移"),
        FixedKey(.code(kVK_RightArrow), opt, "按词右移"),
        FixedKey(.code(kVK_LeftArrow), cmd | shift, "选择到行首"),
        FixedKey(.code(kVK_RightArrow), cmd | shift, "选择到行尾"),
        FixedKey(.code(kVK_LeftArrow), opt | shift, "按词向左选择"),
        FixedKey(.code(kVK_RightArrow), opt | shift, "按词向右选择"),
        FixedKey(.code(kVK_Delete), opt, "删除前一个词"),
        FixedKey(.code(kVK_Delete), cmd, "删除到行首"),
        FixedKey(.code(kVK_ForwardDelete), opt, "删除后一个词"),
        FixedKey(.character("a"), ctrl, "移到行首（文本编辑）"),
        FixedKey(.character("e"), ctrl, "移到行尾（文本编辑）"),
        FixedKey(.character("b"), ctrl, "左移一个字符（文本编辑）"),
        FixedKey(.character("f"), ctrl, "右移一个字符（文本编辑）"),
        FixedKey(.character("p"), ctrl, "上移（文本编辑）"),
        FixedKey(.character("n"), ctrl, "下移（文本编辑）"),
        FixedKey(.character("d"), ctrl, "向后删除（文本编辑）"),
        FixedKey(.character("h"), ctrl, "向前删除（文本编辑）"),
        FixedKey(.character("k"), ctrl, "删除到行尾（文本编辑）"),
        FixedKey(.character("y"), ctrl, "粘回删除的文字（文本编辑）"),
        FixedKey(.character("t"), ctrl, "交换字符（文本编辑）"),
    ]

    /// Command-1 to Command-8 pick a kind, in the order of the filter menu.
    /// Matched by the physical number key, so they work on every layout.
    static let kindDigits = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4,
                             kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8]

    private static var kindKeys: [FixedKey] {
        zip(kindDigits, SearchKind.allCases).map { code, kind in
            FixedKey(.code(code), cmd, "类型筛选：\(kind.title)", .kind(kind))
        }
    }

    static func entry(matching shortcut: Shortcut,
                      character: (UInt32) -> String? = Shortcut.layoutCharacter) -> FixedKey? {
        all.first { $0.matches(shortcut, character: character) }
    }

    /// The panel's own action for a key press, if it has one.
    static func action(for event: NSEvent) -> FixedKey.Action? {
        all.first { $0.action != nil && $0.matches(event) }?.action
    }
}

// MARK: - System shortcuts

enum SystemShortcuts {
    /// The enabled entries of the system's symbolic hot key table: the
    /// shortcuts listed in System Settings > Keyboard > Keyboard Shortcuts
    /// (Spotlight, input sources, screenshots, Mission Control…). Disabled
    /// entries are left out, and so is the Fn flag the table sets on
    /// function and arrow keys. Read afresh each time, since the user can
    /// change them while this application runs.
    static func enabled() -> [Shortcut] {
        var unmanaged: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&unmanaged) == noErr, let list = unmanaged?.takeRetainedValue() as? [[String: Any]]
        else { return [] }
        return list.compactMap { entry in
            guard (entry[kHISymbolicHotKeyEnabled as String] as? Bool) == true,
                  let code = (entry[kHISymbolicHotKeyCode as String] as? NSNumber)?.uint32Value,
                  code < 0xFFFF,
                  let flags = (entry[kHISymbolicHotKeyModifiers as String] as? NSNumber)?.uint32Value
            else { return nil }
            return Shortcut(keyCode: code, modifiers: flags & Shortcut.relevantModifiers)
        }
    }
}

// MARK: - Rules

enum ShortcutProblem: Equatable {
    case sameAsOther(ShortcutRole)
    case fixedKey(String)
    case missingModifier
    case system
    case otherApp

    /// The reason, to follow the combination, for example "已用于“复制完整路径”".
    var reason: String {
        switch self {
        case .sameAsOther(let role): return "已用作“\(role.purpose)”"
        case .fixedKey(let title): return "已用于“\(title)”"
        case .missingModifier: return "需要包含 ⌃、⌥、⌘ 中的至少一个（F1 至 F12 可以单独使用）"
        case .system: return "已被系统快捷键占用"
        case .otherApp: return "已被其他应用占用"
        }
    }

    /// Shown when a newly recorded combination is refused.
    func refusal(for shortcut: Shortcut) -> String {
        "\(shortcut.display)：\(reason)，仍使用原来的快捷键。"
    }

    /// Short label for the self-test output.
    var kind: String {
        switch self {
        case .sameAsOther: return "与另一快捷键相同"
        case .fixedKey: return "与固定按键相同"
        case .missingModifier: return "缺少修饰键"
        case .system: return "系统已占用"
        case .otherApp: return "其他应用已占用"
        }
    }
}

/// A shortcut as read from the user defaults.
struct SavedShortcut {
    /// Nil when the user never changed it, or restored the default.
    var shortcut: Shortcut?
    /// Seconds since 1970 of the last change; 0 when a value was saved by a
    /// version that did not record the time.
    var changedAt: Double
}

enum ShortcutRules {
    static let functionKeys: Set<UInt32> = Set([
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12,
    ].map(UInt32.init))

    /// At least one of Control, Option and Command, so that ordinary typing
    /// (with or without Shift) is never taken. F1 to F12 type nothing and
    /// may stand alone.
    static func isAllowed(_ shortcut: Shortcut) -> Bool {
        shortcut.modifiers & UInt32(controlKey | optionKey | cmdKey) != 0 || functionKeys.contains(shortcut.keyCode)
    }

    /// Why `shortcut` cannot be used for `role`, or nil when it can.
    /// `other` is the current value of the other shortcut and `system` the
    /// enabled system shortcuts. Shortcuts other applications registered
    /// cannot be looked up; they show up only when registration fails.
    static func problem(with shortcut: Shortcut, for role: ShortcutRole, other: Shortcut, system: [Shortcut],
                        character: (UInt32) -> String? = Shortcut.layoutCharacter) -> ShortcutProblem? {
        if shortcut == other { return .sameAsOther(role.other) }
        if let fixed = PanelKeys.entry(matching: shortcut, character: character) { return .fixedKey(fixed.title) }
        if !isAllowed(shortcut) { return .missingModifier }
        if system.contains(shortcut) { return .system }
        return nil
    }

    /// The startup check. A saved shortcut that is no longer allowed, or
    /// that a fixed key uses, goes back to its default. When the two are
    /// the same, the one changed later goes back to its default; a shortcut
    /// at its default counts as never changed.
    static func resolve(global: SavedShortcut, preview: SavedShortcut,
                        character: (UInt32) -> String? = Shortcut.layoutCharacter)
        -> (values: [ShortcutRole: Shortcut], notices: [ShortcutRole: String]) {
        let saved: [ShortcutRole: SavedShortcut] = [.global: global, .preview: preview]
        var values: [ShortcutRole: Shortcut] = [:]
        var notices: [ShortcutRole: String] = [:]
        for role in ShortcutRole.allCases {
            let value = saved[role]?.shortcut ?? role.standard
            values[role] = value
            guard value != role.standard else { continue }
            let problem: ShortcutProblem?
            if let fixed = PanelKeys.entry(matching: value, character: character) {
                problem = .fixedKey(fixed.title)
            } else if !isAllowed(value) {
                problem = .missingModifier
            } else {
                problem = nil
            }
            if let problem {
                values[role] = role.standard
                notices[role] = restoredNotice(value, problem)
            }
        }
        if values[.global] == values[.preview] {
            func changedAt(_ role: ShortcutRole) -> Double {
                values[role] == role.standard ? -1 : saved[role]?.changedAt ?? 0
            }
            let later: ShortcutRole = changedAt(.global) > changedAt(.preview) ? .global : .preview
            let value = values[later]!
            values[later] = later.standard
            // The two defaults differ, and the other one keeps its value, so
            // this cannot clash again.
            notices[later] = restoredNotice(value, .sameAsOther(later.other))
        }
        return (values, notices)
    }

    static func restoredNotice(_ shortcut: Shortcut, _ problem: ShortcutProblem) -> String {
        "上次设置的 \(shortcut.display) \(problem.reason)，已恢复默认。"
    }
}

// MARK: - Live state

/// Holds the two shortcuts, applies the rules to every change and keeps
/// them in the user defaults.
final class ShortcutCenter {
    private let hotKey: HotKey
    private(set) var preview: Shortcut = ShortcutRole.preview.standard
    /// One-off explanations from the startup check, shown in the settings
    /// window until that shortcut is changed.
    private(set) var notices: [ShortcutRole: String] = [:]
    /// Called after either shortcut changed.
    var onChange: (() -> Void)?

    init(hotKey: HotKey) {
        self.hotKey = hotKey
    }

    func current(_ role: ShortcutRole) -> Shortcut {
        switch role {
        case .global: return hotKey.shortcut ?? role.standard
        case .preview: return preview
        }
    }

    /// The global shortcut actually registered, if any.
    var registeredGlobal: Shortcut? { hotKey.shortcut }

    func start() {
        let saved = ShortcutRules.resolve(global: Shortcut.stored(.global), preview: Shortcut.stored(.preview))
        notices = saved.notices
        preview = saved.values[.preview]!
        var global = saved.values[.global]!
        // A combination the system has taken since, or that another
        // application registered first, falls back to the default.
        if SystemShortcuts.enabled().contains(global) || !hotKey.register(global) {
            if global != ShortcutRole.global.standard {
                notices[.global] = "上次设置的 \(global.display) 已被系统或其他应用占用，已恢复默认。"
            }
            global = ShortcutRole.global.standard
            _ = hotKey.register(global)
            if preview == global {
                notices[.preview] = ShortcutRules.restoredNotice(preview, .sameAsOther(.global))
                preview = ShortcutRole.preview.standard
            }
        }
        // Keep what was put right, so the notices appear only once.
        for (role, value) in [(ShortcutRole.global, global), (.preview, preview)]
        where Shortcut.stored(role).shortcut ?? role.standard != value {
            value.save(as: role)
        }
        onChange?()
    }

    /// Switches `role` to `shortcut`, or explains why it cannot.
    func change(_ role: ShortcutRole, to shortcut: Shortcut) -> ShortcutProblem? {
        notices[role] = nil
        guard shortcut != current(role) || (role == .global && hotKey.shortcut == nil) else { return nil }
        if let problem = ShortcutRules.problem(with: shortcut, for: role, other: current(role.other),
                                               system: SystemShortcuts.enabled()) {
            return problem
        }
        switch role {
        case .global: guard hotKey.register(shortcut) else { return .otherApp }
        case .preview: preview = shortcut
        }
        shortcut.save(as: role)
        onChange?()
        return nil
    }

    /// Whether the system now uses `role`'s combination, which means the
    /// key press never reaches the search panel.
    func isTakenBySystem(_ role: ShortcutRole) -> Bool {
        SystemShortcuts.enabled().contains(current(role))
    }

    /// While a new shortcut is being recorded, pressing the global one must
    /// reach the recorder rather than open the panel.
    func suspendGlobal() { hotKey.suspend() }
    func resumeGlobal() { hotKey.resume() }
}
