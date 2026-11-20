import AppKit
import Carbon.HIToolbox

/// `SearchApp --self-test-shortcuts`: runs the shortcut rules against a
/// fixed set of cases and the system shortcuts enabled on this Mac, prints
/// one line per case and reports whether all passed. Touches no settings.
enum ShortcutSelfTest {
    private static var passed = 0
    private static var failed = 0

    static func run() -> Bool {
        let system = SystemShortcuts.enabled()
        let globalDefault = ShortcutRole.global.standard
        let previewDefault = ShortcutRole.preview.standard
        print("快捷键规则自检（本机已启用的系统快捷键 \(system.count) 个）")
        print("格式：用途 | 组合 | 期望 | 实际 | 结果")

        func check(_ role: ShortcutRole, _ shortcut: Shortcut, expect: ShortcutProblem?, note: String = "") {
            let other = role == .global ? previewDefault : globalDefault
            let actual = ShortcutRules.problem(with: shortcut, for: role, other: other, system: system)
            let ok = actual?.kind == expect?.kind
            record(ok, "\(role.title) | \(shortcut.display)\(note) | \(expect?.kind ?? "可以使用") | "
                + "\(actual.map { "\($0.kind)：\($0.reason)" } ?? "可以使用")")
        }

        print("\n一、两个自定义快捷键相同")
        check(.preview, globalDefault, expect: .sameAsOther(.global))
        check(.global, previewDefault, expect: .sameAsOther(.preview))

        print("\n二、与固定按键相同（两种用途都应拒绝）")
        for fixed in PanelKeys.all {
            guard let shortcut = shortcut(for: fixed) else {
                record(false, "\(fixed.display)（\(fixed.title)）| 当前键盘布局找不到这个键")
                continue
            }
            for role in ShortcutRole.allCases {
                check(role, shortcut, expect: .fixedKey(fixed.title), note: "（\(fixed.title)）")
            }
        }

        print("\n三、修饰键规则")
        let letterA = key("a"), letterJ = key("j")
        check(.preview, Shortcut(keyCode: letterA, modifiers: UInt32(shiftKey)), expect: .missingModifier, note: "（只有 Shift）")
        check(.global, Shortcut(keyCode: letterA, modifiers: UInt32(shiftKey)), expect: .missingModifier, note: "（只有 Shift）")
        check(.preview, Shortcut(keyCode: letterJ, modifiers: 0), expect: .missingModifier, note: "（没有修饰键）")
        check(.preview, Shortcut(keyCode: UInt32(kVK_Space), modifiers: 0), expect: .missingModifier, note: "（单独的空格）")
        check(.preview, Shortcut(keyCode: UInt32(kVK_F13), modifiers: 0), expect: .missingModifier, note: "（F13 不在 F1 至 F12 内）")
        let functionKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                            kVK_F11, kVK_F12].map { Shortcut(keyCode: UInt32($0), modifiers: 0) }
        if let free = functionKeys.first(where: { !system.contains($0) }) {
            check(.preview, free, expect: nil, note: "（功能键不带修饰键）")
            check(.global, free, expect: nil, note: "（功能键不带修饰键）")
        }
        if let taken = functionKeys.first(where: { system.contains($0) }) {
            check(.preview, taken, expect: .system, note: "（功能键不带修饰键，本机系统已占用）")
        }

        print("\n四、与系统已启用的快捷键相同（取本机实际读到的）")
        let candidates = system.filter {
            ShortcutRules.isAllowed($0) && PanelKeys.entry(matching: $0) == nil
                && $0 != globalDefault && $0 != previewDefault
        }
        if candidates.isEmpty {
            record(false, "本机没有读到可用于测试的系统快捷键")
        }
        // Space combinations (Spotlight, input sources) first: the likeliest clashes.
        let ordered = candidates.filter { $0.keyCode == UInt32(kVK_Space) }
            + candidates.filter { $0.keyCode != UInt32(kVK_Space) }
        for shortcut in ordered.prefix(4) {
            check(.preview, shortcut, expect: .system)
            check(.global, shortcut, expect: .system)
        }

        print("\n五、合法的新组合")
        let fresh = [("j", controlKey | optionKey), ("p", controlKey | optionKey), ("k", cmdKey | shiftKey | optionKey)]
            .map { Shortcut(keyCode: key($0.0), modifiers: UInt32($0.1)) }
            .filter { !system.contains($0) }
        for shortcut in fresh.prefix(2) {
            check(.preview, shortcut, expect: nil)
            check(.global, shortcut, expect: nil)
        }

        print("\n六、启动时自检（保存的设置互相冲突或与固定按键冲突）")
        let optionSpace = previewDefault
        let controlOptionJ = Shortcut(keyCode: letterJ, modifiers: UInt32(controlKey | optionKey))
        let commandC = Shortcut(keyCode: key("c"), modifiers: UInt32(cmdKey))
        resolveCase("旧版本把全局设为 ⌥空格，预览为默认",
                    global: SavedShortcut(shortcut: optionSpace, changedAt: 0),
                    preview: SavedShortcut(shortcut: nil, changedAt: 0),
                    expect: (globalDefault, previewDefault), reset: [.global])
        resolveCase("两个都设为 ⌃⌥J，预览后改",
                    global: SavedShortcut(shortcut: controlOptionJ, changedAt: 100),
                    preview: SavedShortcut(shortcut: controlOptionJ, changedAt: 200),
                    expect: (controlOptionJ, previewDefault), reset: [.preview])
        resolveCase("两个都设为 ⌃⌥J，全局后改",
                    global: SavedShortcut(shortcut: controlOptionJ, changedAt: 300),
                    preview: SavedShortcut(shortcut: controlOptionJ, changedAt: 200),
                    expect: (globalDefault, controlOptionJ), reset: [.global])
        resolveCase("全局保存为固定按键 ⌘C",
                    global: SavedShortcut(shortcut: commandC, changedAt: 0),
                    preview: SavedShortcut(shortcut: nil, changedAt: 0),
                    expect: (globalDefault, previewDefault), reset: [.global])
        resolveCase("预览保存为只有 Shift 的 ⇧A",
                    global: SavedShortcut(shortcut: nil, changedAt: 0),
                    preview: SavedShortcut(shortcut: Shortcut(keyCode: letterA, modifiers: UInt32(shiftKey)), changedAt: 50),
                    expect: (globalDefault, previewDefault), reset: [.preview])
        resolveCase("预览保存为 ⌥⇧空格，全局为默认（与之相同）",
                    global: SavedShortcut(shortcut: nil, changedAt: 0),
                    preview: SavedShortcut(shortcut: globalDefault, changedAt: 100),
                    expect: (globalDefault, previewDefault), reset: [.preview])
        resolveCase("没有冲突，保持不变",
                    global: SavedShortcut(shortcut: controlOptionJ, changedAt: 100),
                    preview: SavedShortcut(shortcut: nil, changedAt: 0),
                    expect: (controlOptionJ, previewDefault), reset: [])

        // Not a shortcut rule, but checked here so that it runs without
        // building a release bundle and starting it.
        print("\n附：各版本的数据目录（索引 | 缓存）")
        let directoryCases: [(String?, String, String)] = [
            ("io.github.nongtanpeidanjiu.suoyin", "io.github.nongtanpeidanjiu.suoyin", "io.github.nongtanpeidanjiu.suoyin"),
            ("dev.local.filesearch.demo", "dev.local.filesearch", "dev.local.filesearch.demo"),
            (nil, "dev.local.filesearch", "dev.local.filesearch"),
        ]
        for (identifier, data, caches) in directoryCases {
            let actualData = AppDirectories.dataFolderName(bundleIdentifier: identifier)
            let actualCaches = AppDirectories.cachesFolderName(bundleIdentifier: identifier)
            record(actualData == data && actualCaches == caches,
                   "\(identifier ?? "（不在包里）") | 期望 \(data) | \(caches) | 实际 \(actualData) | \(actualCaches)")
        }

        print("\n合计：通过 \(passed) 项，失败 \(failed) 项。")
        return failed == 0
    }

    private static func record(_ ok: Bool, _ line: String) {
        if ok { passed += 1 } else { failed += 1 }
        print("\(line) | \(ok ? "通过" : "失败")")
    }

    private static func resolveCase(_ title: String, global: SavedShortcut, preview: SavedShortcut,
                                    expect: (Shortcut, Shortcut), reset: Set<ShortcutRole>) {
        let result = ShortcutRules.resolve(global: global, preview: preview)
        let values = (result.values[.global]!, result.values[.preview]!)
        let ok = values == expect && Set(result.notices.keys) == reset
        let notes = ShortcutRole.allCases.compactMap { role in result.notices[role].map { "\(role.title)：\($0)" } }
        record(ok, "\(title) | 期望 全局 \(expect.0.display)、预览 \(expect.1.display) | "
            + "实际 全局 \(values.0.display)、预览 \(values.1.display)"
            + (notes.isEmpty ? "，无说明" : "，说明：" + notes.joined(separator: "；")))
    }

    /// The key that types `character` on the current layout.
    private static func key(_ character: String) -> UInt32 {
        (0..<128).map(UInt32.init).first { Shortcut.layoutCharacter($0) == character } ?? 0xFFFF
    }

    private static func shortcut(for fixed: FixedKey) -> Shortcut? {
        switch fixed.key {
        case .code(let code): return Shortcut(keyCode: UInt32(code), modifiers: fixed.modifiers)
        case .character(let text):
            let code = key(text)
            return code == 0xFFFF ? nil : Shortcut(keyCode: code, modifiers: fixed.modifiers)
        }
    }
}
