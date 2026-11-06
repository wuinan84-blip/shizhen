import AppKit
import Carbon.HIToolbox

/// 一个按键组合：键码 + 修饰键。
struct KeyCombo: Codable, Equatable, Hashable {
    var keyCode: UInt16
    /// 只保存 ⌃⌥⇧⌘ 四个修饰键（NSEvent.ModifierFlags 的 rawValue）。
    var modifiers: UInt

    static let relevantModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection(Self.relevantModifiers).rawValue
    }

    init(event: NSEvent) {
        self.init(keyCode: event.keyCode, modifiers: event.modifierFlags)
    }

    var modifierFlags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    func matches(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(Self.relevantModifiers)
        guard flags == modifierFlags else { return false }
        if event.keyCode == keyCode { return true }
        // 主键盘回车和小键盘回车视为同一个键
        let enterKeys: Set<UInt16> = [UInt16(kVK_Return), UInt16(kVK_ANSI_KeypadEnter)]
        return enterKeys.contains(keyCode) && enterKeys.contains(event.keyCode)
    }

    var carbonModifiers: UInt32 {
        var m: UInt32 = 0
        let f = modifierFlags
        if f.contains(.command) { m |= UInt32(cmdKey) }
        if f.contains(.option) { m |= UInt32(optionKey) }
        if f.contains(.control) { m |= UInt32(controlKey) }
        if f.contains(.shift) { m |= UInt32(shiftKey) }
        return m
    }

    var displayString: String {
        var s = ""
        let f = modifierFlags
        if f.contains(.control) { s += "⌃" }
        if f.contains(.option) { s += "⌥" }
        if f.contains(.shift) { s += "⇧" }
        if f.contains(.command) { s += "⌘" }
        return s + Self.keyName(keyCode)
    }

    static func keyName(_ code: UInt16) -> String {
        if let special = specialKeyNames[Int(code)] { return special }
        if let ch = character(for: code) { return ch.uppercased() }
        return "Key\(code)"
    }

    private static let specialKeyNames: [Int: String] = [
        kVK_Return: "↩", kVK_ANSI_KeypadEnter: "⌤", kVK_Escape: "Esc", kVK_Tab: "⇥",
        kVK_Space: "空格", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17",
        kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
    ]

    /// 用当前键盘布局把键码翻译成字符。
    private static func character(for code: UInt16) -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        return data.withUnsafeBytes { raw -> String? in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            var deadKeys: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length = 0
            let status = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDisplay), 0,
                                        UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                        &deadKeys, chars.count, &length, &chars)
            guard status == noErr, length > 0 else { return nil }
            let s = String(utf16CodeUnits: chars, count: length)
            return s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : s
        }
    }

    /// 是否至少带一个修饰键（全局快捷键必须带修饰键，避免影响正常打字）。
    var hasModifier: Bool { !modifierFlags.isEmpty }
}

/// 应用里所有可自定义的快捷键。
enum ShortcutAction: String, CaseIterable, Codable, Identifiable {
    case capture        // 全局：进入截图 / 录屏
    case cancel         // 截图中：叉
    case confirm        // 截图中：对勾
    case save           // 截图中：下载
    case undo
    case redo
    case cancelCountdown

    var id: String { rawValue }

    var title: String {
        switch self {
        case .capture: return "进入截图 / 录屏（全局）"
        case .cancel: return "放弃并退出（叉）"
        case .confirm: return "复制到剪贴板（对勾）"
        case .save: return "下载"
        case .undo: return "撤销"
        case .redo: return "重做"
        case .cancelCountdown: return "录屏倒计时中取消录制"
        }
    }

    var isGlobal: Bool { self == .capture }

    var defaultCombo: KeyCombo {
        switch self {
        case .capture: return KeyCombo(keyCode: UInt16(kVK_ANSI_A), modifiers: [.control, .option])
        case .cancel: return KeyCombo(keyCode: UInt16(kVK_Escape), modifiers: [])
        case .confirm: return KeyCombo(keyCode: UInt16(kVK_Return), modifiers: [])
        case .save: return KeyCombo(keyCode: UInt16(kVK_ANSI_S), modifiers: [.command])
        case .undo: return KeyCombo(keyCode: UInt16(kVK_ANSI_Z), modifiers: [.command])
        case .redo: return KeyCombo(keyCode: UInt16(kVK_ANSI_Z), modifiers: [.command, .shift])
        case .cancelCountdown: return KeyCombo(keyCode: UInt16(kVK_Escape), modifiers: [])
        }
    }

    /// 同时生效、因此不能重复的快捷键分组。
    /// 截图编辑中的快捷键彼此不能重复；倒计时只有一个快捷键，单独一组；全局快捷键和所有快捷键都不能重复。
    var conflictGroup: Int {
        switch self {
        case .capture: return 0
        case .cancelCountdown: return 2
        default: return 1
        }
    }
}
