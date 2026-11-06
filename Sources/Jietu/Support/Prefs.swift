import AppKit
import Combine

enum ToolKind: String, CaseIterable, Codable {
    case rect, ellipse, arrow, line, mosaic, text, label, highlight

    var title: String {
        switch self {
        case .rect: return "矩形"
        case .ellipse: return "椭圆"
        case .arrow: return "箭头"
        case .line: return "直线"
        case .mosaic: return "马赛克"
        case .text: return "文字"
        case .label: return "标签"
        case .highlight: return "高亮"
        }
    }

    var usesFontSize: Bool { self == .text || self == .label }
}

enum MosaicMode: String, Codable { case box, brush }

enum TranslateEngine: String, Codable { case apple, baidu }

/// 6 种标注颜色。
enum Palette {
    static let colors: [NSColor] = [
        NSColor(hex: 0xF54A45), NSColor(hex: 0xFFC60A), NSColor(hex: 0x34C724),
        NSColor(hex: 0x3370FF), NSColor(hex: 0x1F2329), NSColor(hex: 0xFFFFFF),
    ]
    static let names = ["红", "黄", "绿", "蓝", "黑", "白"]

    static func color(_ index: Int) -> NSColor { colors[max(0, min(colors.count - 1, index))] }
}

/// 粗细、字号的三档数值。
enum StyleLevels {
    static let stroke: [CGFloat] = [2, 4, 6]
    static let mosaicBrush: [CGFloat] = [12, 20, 28]
    static let font: [CGFloat] = [14, 18, 24]
    /// 高亮是覆盖一行文字的色带，用和字号同量级的宽度
    static let highlight: [CGFloat] = [12, 18, 24]
}

/// 每个工具各自记住的样式。颜色为 nil 表示从未选过。
struct ToolStyle: Codable, Equatable {
    var colorIndex: Int?
    var level: Int = 1
}

final class Prefs: ObservableObject {
    static let shared = Prefs()

    private let defaults = UserDefaults.standard

    @Published private(set) var shortcuts: [ShortcutAction: KeyCombo] = [:]
    @Published private(set) var toolStyles: [ToolKind: ToolStyle] = [:]
    @Published var mosaicMode: MosaicMode {
        didSet { defaults.set(mosaicMode.rawValue, forKey: "mosaicMode") }
    }
    @Published var translateEngine: TranslateEngine {
        didSet { defaults.set(translateEngine.rawValue, forKey: "translateEngine") }
    }

    var lastSaveDirectory: URL? {
        get { defaults.url(forKey: "lastSaveDirectory") }
        set { defaults.set(newValue, forKey: "lastSaveDirectory") }
    }

    var didInitializeLoginItem: Bool {
        get { defaults.bool(forKey: "didInitializeLoginItem") }
        set { defaults.set(newValue, forKey: "didInitializeLoginItem") }
    }

    var didShowOnboarding: Bool {
        get { defaults.bool(forKey: "didShowOnboarding") }
        set { defaults.set(newValue, forKey: "didShowOnboarding") }
    }

    private init() {
        mosaicMode = MosaicMode(rawValue: defaults.string(forKey: "mosaicMode") ?? "") ?? .box
        translateEngine = TranslateEngine(rawValue: defaults.string(forKey: "translateEngine") ?? "") ?? .apple
        if let data = defaults.data(forKey: "shortcuts"),
           let decoded = try? JSONDecoder().decode([String: KeyCombo].self, from: data) {
            for (k, v) in decoded { if let a = ShortcutAction(rawValue: k) { shortcuts[a] = v } }
        }
        if let data = defaults.data(forKey: "toolStyles"),
           let decoded = try? JSONDecoder().decode([String: ToolStyle].self, from: data) {
            for (k, v) in decoded { if let t = ToolKind(rawValue: k) { toolStyles[t] = v } }
        }
    }

    // MARK: 快捷键

    func shortcut(_ action: ShortcutAction) -> KeyCombo { shortcuts[action] ?? action.defaultCombo }

    func setShortcut(_ combo: KeyCombo, for action: ShortcutAction) {
        shortcuts[action] = combo
        saveShortcuts()
    }

    func resetShortcuts() {
        shortcuts = [:]
        saveShortcuts()
    }

    private func saveShortcuts() {
        let dict = Dictionary(uniqueKeysWithValues: shortcuts.map { ($0.key.rawValue, $0.value) })
        defaults.set(try? JSONEncoder().encode(dict), forKey: "shortcuts")
        NotificationCenter.default.post(name: .shortcutsChanged, object: nil)
    }

    /// 返回与给定组合冲突的本应用快捷键（不含自己）。
    func internalConflict(_ combo: KeyCombo, for action: ShortcutAction) -> ShortcutAction? {
        for other in ShortcutAction.allCases where other != action {
            let sameGroup = other.conflictGroup == action.conflictGroup || other.isGlobal || action.isGlobal
            if sameGroup && shortcut(other) == combo { return other }
        }
        return nil
    }

    // MARK: 工具样式

    func style(_ tool: ToolKind) -> ToolStyle { toolStyles[tool] ?? ToolStyle() }

    func setColor(_ index: Int, for tool: ToolKind) {
        var s = style(tool); s.colorIndex = index; toolStyles[tool] = s; saveStyles()
    }

    func setLevel(_ level: Int, for tool: ToolKind) {
        var s = style(tool); s.level = max(0, min(2, level)); toolStyles[tool] = s; saveStyles()
    }

    /// 当前工具的线宽 / 笔刷宽度 / 字号。
    func sizeValue(_ tool: ToolKind) -> CGFloat {
        let level = style(tool).level
        switch tool {
        case .text, .label: return StyleLevels.font[level]
        case .mosaic: return StyleLevels.mosaicBrush[level]
        case .highlight: return StyleLevels.highlight[level]
        default: return StyleLevels.stroke[level]
        }
    }

    private func saveStyles() {
        let dict = Dictionary(uniqueKeysWithValues: toolStyles.map { ($0.key.rawValue, $0.value) })
        defaults.set(try? JSONEncoder().encode(dict), forKey: "toolStyles")
    }
}

extension Notification.Name {
    static let shortcutsChanged = Notification.Name("JietuShortcutsChanged")
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }
}
