import AppKit

enum UIStyle {
    static let text = NSColor(hex: 0x1F2329)
    static let secondary = NSColor(hex: 0x646A73)
    static let blue = NSColor(hex: 0x3370FF)
    static let red = NSColor(hex: 0xF54A45)
    static let separator = NSColor(hex: 0xDEE0E3)
    static let disabled = NSColor(hex: 0xBBBFC4)
}

func symbolImage(_ names: [String], pointSize: CGFloat = 16, weight: NSFont.Weight = .regular) -> NSImage? {
    for name in names {
        if let img = NSImage(systemSymbolName: name, accessibilityDescription: nil) {
            return img.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight))
        }
    }
    return nil
}

private func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
    image.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [color])) ?? image
}

/// 把一个字母画成和 SF Symbols 差不多大小的图标（SF Symbols 里没有单独的「T」）。
func glyphImage(_ glyph: String, pointSize: CGFloat, color: NSColor) -> NSImage {
    let font = NSFont.systemFont(ofSize: pointSize + 1, weight: .light)
    let side = ceil(pointSize + 4)
    return NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let width = (glyph as NSString).size(withAttributes: attrs).width
        // 让大写字母的高度在图标里垂直居中
        let baseline = (rect.height - font.capHeight) / 2
        (glyph as NSString).draw(at: NSPoint(x: (rect.width - width) / 2, y: baseline + font.descender), withAttributes: attrs)
        return true
    }
}

/// 悬停提示。系统 toolTip 的窗口层级低于截图遮罩，会被挡住，所以自己显示。
final class HoverTip {
    static let shared = HoverTip()
    private var panel: NSPanel?
    private let label = NSTextField(labelWithString: "")
    private var pending: DispatchWorkItem?
    private weak var owner: NSView?

    func schedule(_ text: String, for view: NSView) {
        hide()
        owner = view
        let work = DispatchWorkItem { [weak self, weak view] in
            guard let self, let view, view.window?.isVisible == true else { return }
            self.show(text, below: view)
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// 传入 view 时，只有当前提示属于它才隐藏。
    func hide(for view: NSView? = nil) {
        if let view, owner !== view { return }
        pending?.cancel()
        pending = nil
        panel?.orderOut(nil)
    }

    private func show(_ text: String, below view: NSView) {
        guard let window = view.window else { return }
        let p = panel ?? makePanel()
        label.stringValue = text
        let size = label.fittingSize
        let tipSize = CGSize(width: ceil(size.width) + 16, height: ceil(size.height) + 8)
        label.frame = CGRect(x: 8, y: 4, width: ceil(size.width), height: ceil(size.height))
        let r = window.convertToScreen(view.convert(view.bounds, to: nil))
        var origin = CGPoint(x: r.midX - tipSize.width / 2, y: r.minY - tipSize.height - 6)
        if let frame = window.screen?.frame {
            if origin.y < frame.minY + 2 { origin.y = r.maxY + 6 }
            origin.x = min(max(origin.x, frame.minX + 4), frame.maxX - tipSize.width - 4)
        }
        p.setFrame(CGRect(origin: origin, size: tipSize), display: true)
        p.level = NSWindow.Level(rawValue: max(window.level.rawValue, NSWindow.Level.capturePanel.rawValue) + 1)
        p.orderFront(nil)
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.sharingType = .none
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let bg = NSView()
        bg.wantsLayer = true
        bg.layer?.backgroundColor = UIStyle.text.withAlphaComponent(0.92).cgColor
        bg.layer?.cornerRadius = 4
        label.font = .systemFont(ofSize: 12)
        label.textColor = .white
        bg.addSubview(label)
        p.contentView = bg
        panel = p
        return p
    }
}

/// 带悬停提示的控件基类。
class HoverTipView: NSView {
    var tip: String? {
        didSet { if tip == nil { HoverTip.shared.hide(for: self) } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseEntered(with event: NSEvent) {
        if let tip { HoverTip.shared.schedule(tip, for: self) }
    }

    override func mouseExited(with event: NSEvent) { HoverTip.shared.hide(for: self) }
    override func mouseDown(with event: NSEvent) { HoverTip.shared.hide(for: self) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { HoverTip.shared.hide(for: self) }
    }
}

/// 工具栏按钮：图标、文字或图标 + 文字。
final class IconButton: HoverTipView {
    enum Style { case plain, segment, filled(NSColor) }

    var action: (() -> Void)?
    var isSelected = false { didSet { needsDisplay = true } }
    var isEnabled = true { didSet { needsDisplay = true } }
    var tintColor = UIStyle.text { didSet { needsDisplay = true } }
    var title: String? { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }

    private let image: NSImage?
    /// 用字母代替 SF Symbols 图标（如文字工具的「T」）。
    private let glyph: String?
    private let pointSize: CGFloat
    private let style: Style
    private let height: CGFloat
    private var hovering = false
    private var pressed = false

    init(symbols: [String] = [], glyph: String? = nil, title: String? = nil, tooltip: String? = nil, style: Style = .plain,
         height: CGFloat = 30, pointSize: CGFloat = 16) {
        self.image = symbols.isEmpty ? nil : symbolImage(symbols, pointSize: pointSize)
        self.glyph = glyph
        self.pointSize = pointSize
        self.title = title
        self.style = style
        self.height = height
        super.init(frame: .zero)
        tip = tooltip
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError() }

    private var titleFont: NSFont { NSFont.systemFont(ofSize: 13, weight: .medium) }

    private func icon(_ color: NSColor) -> NSImage? {
        if let image { return tinted(image, color) }
        if let glyph { return glyphImage(glyph, pointSize: pointSize, color: color) }
        return nil
    }

    override var intrinsicContentSize: NSSize {
        var w: CGFloat = 0
        let iconSize = icon(tintColor)?.size
        if let iconSize { w += iconSize.width }
        if let title {
            let tw = ceil((title as NSString).size(withAttributes: [.font: titleFont]).width)
            w += tw + (iconSize != nil ? 5 : 0)
            return NSSize(width: max(w + 20, height), height: height)
        }
        return NSSize(width: height, height: height)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        hovering = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hovering = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        guard isEnabled else { return }
        pressed = true
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let wasPressed = pressed
        pressed = false
        needsDisplay = true
        let p = convert(event.locationInWindow, from: nil)
        if wasPressed, isEnabled, bounds.contains(p) { action?() }
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 1, dy: 1)
        var fg = isEnabled ? tintColor : UIStyle.disabled
        let path = NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5)
        switch style {
        case .filled(let color):
            (pressed ? color.blended(withFraction: 0.15, of: .black) ?? color : color).setFill()
            path.fill()
            fg = .white
        case .segment:
            if isSelected {
                UIStyle.blue.setFill(); path.fill(); fg = .white
            } else if pressed || hovering {
                NSColor.black.withAlphaComponent(pressed ? 0.12 : 0.06).setFill(); path.fill()
            }
        case .plain:
            if pressed && isEnabled {
                NSColor.black.withAlphaComponent(0.12).setFill(); path.fill()
            } else if isSelected {
                UIStyle.blue.withAlphaComponent(0.12).setFill(); path.fill()
            } else if hovering && isEnabled {
                NSColor.black.withAlphaComponent(0.06).setFill(); path.fill()
            }
            if isSelected && isEnabled { fg = UIStyle.blue }
        }

        var contentWidth: CGFloat = 0
        let attrs: [NSAttributedString.Key: Any] = [.font: titleFont, .foregroundColor: fg]
        let titleSize = title.map { ($0 as NSString).size(withAttributes: attrs) } ?? .zero
        let iconImage = icon(fg)
        if let iconImage { contentWidth += iconImage.size.width }
        if title != nil { contentWidth += titleSize.width + (iconImage != nil ? 5 : 0) }
        var x = (bounds.width - contentWidth) / 2
        if let img = iconImage {
            let y = (bounds.height - img.size.height) / 2
            img.draw(in: NSRect(x: x, y: y, width: img.size.width, height: img.size.height))
            x += img.size.width + 5
        }
        if let title {
            (title as NSString).draw(at: NSPoint(x: x, y: (bounds.height - titleSize.height) / 2), withAttributes: attrs)
        }
    }
}

/// 颜色色块。
final class ColorSwatch: HoverTipView {
    var action: (() -> Void)?
    var isSelected = false { didSet { needsDisplay = true } }
    let color: NSColor

    init(color: NSColor, tooltip: String) {
        self.color = color
        super.init(frame: .zero)
        tip = tooltip
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: 26, height: 30) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action?() }
    }

    override func draw(_ dirtyRect: NSRect) {
        let c = NSPoint(x: bounds.midX, y: bounds.midY)
        if isSelected {
            let ring = NSBezierPath(ovalIn: NSRect(x: c.x - 10, y: c.y - 10, width: 20, height: 20))
            ring.lineWidth = 2
            UIStyle.blue.setStroke()
            ring.stroke()
        }
        let dot = NSBezierPath(ovalIn: NSRect(x: c.x - 7, y: c.y - 7, width: 14, height: 14))
        color.setFill()
        dot.fill()
        if color.whiteComponentIfGray > 0.9 {
            UIStyle.separator.setStroke()
            dot.lineWidth = 1
            dot.stroke()
        }
    }
}

private extension NSColor {
    var whiteComponentIfGray: CGFloat {
        guard let c = usingColorSpace(.sRGB) else { return 0 }
        return min(c.redComponent, c.greenComponent, c.blueComponent)
    }
}

/// 粗细 / 字号档位按钮。
final class LevelButton: HoverTipView {
    enum Kind { case dot(CGFloat), glyph(CGFloat) }
    var action: (() -> Void)?
    var isSelected = false { didSet { needsDisplay = true } }
    private let kind: Kind

    init(kind: Kind, tooltip: String) {
        self.kind = kind
        super.init(frame: .zero)
        tip = tooltip
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: 28, height: 30) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action?() }
    }

    override func draw(_ dirtyRect: NSRect) {
        if isSelected {
            UIStyle.blue.withAlphaComponent(0.12).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5).fill()
        }
        let color = isSelected ? UIStyle.blue : UIStyle.text
        switch kind {
        case .dot(let d):
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: bounds.midX - d / 2, y: bounds.midY - d / 2, width: d, height: d)).fill()
        case .glyph(let size):
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: .semibold), .foregroundColor: color]
            let s = ("A" as NSString).size(withAttributes: attrs)
            ("A" as NSString).draw(at: NSPoint(x: bounds.midX - s.width / 2, y: bounds.midY - s.height / 2), withAttributes: attrs)
        }
    }
}

/// 录制设置栏里的开关：文字 + 小开关。
final class ToggleChip: NSView {
    var action: (() -> Void)?
    var isOn = false { didSet { needsDisplay = true } }
    private let title: String

    init(title: String) {
        self.title = title
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { fatalError() }

    private var font: NSFont { NSFont.systemFont(ofSize: 13) }

    override var intrinsicContentSize: NSSize {
        let w = ceil((title as NSString).size(withAttributes: [.font: font]).width)
        return NSSize(width: w + 8 + 26 + 12, height: 30)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action?() }
    }

    override func draw(_ dirtyRect: NSRect) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIStyle.text]
        let s = (title as NSString).size(withAttributes: attrs)
        (title as NSString).draw(at: NSPoint(x: 6, y: (bounds.height - s.height) / 2), withAttributes: attrs)
        let track = NSRect(x: 6 + ceil(s.width) + 8, y: bounds.midY - 8, width: 26, height: 16)
        (isOn ? UIStyle.blue : UIStyle.separator).setFill()
        NSBezierPath(roundedRect: track, xRadius: 8, yRadius: 8).fill()
        let knobX = isOn ? track.maxX - 14 : track.minX + 2
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: knobX, y: track.minY + 2, width: 12, height: 12)).fill()
    }
}

final class SeparatorView: NSView {
    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = UIStyle.separator.cgColor
        widthAnchor.constraint(equalToConstant: 1).isActive = true
        heightAnchor.constraint(equalToConstant: 18).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// 白色圆角浮动条，内部是横向排列的控件。
class BarView: NSView {
    let stack = NSStackView()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.cgColor
        layer?.cornerRadius = 7
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.22
        layer?.shadowRadius = 8
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        layer?.masksToBounds = false
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// 吃掉空白处的点击，避免穿透到下面的选区。
    override func mouseDown(with event: NSEvent) {}

    var fittingBarSize: NSSize {
        stack.layoutSubtreeIfNeeded()
        let s = stack.fittingSize
        return NSSize(width: ceil(s.width), height: ceil(s.height))
    }

    func setViews(_ views: [NSView]) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        views.forEach { stack.addArrangedSubview($0) }
    }
}

// MARK: - 模式切换条

enum CaptureMode { case screenshot, record }

final class ModeBar: BarView {
    var onChange: ((CaptureMode) -> Void)?
    private let shot = IconButton(symbols: ["scissors"], title: "截图", style: .segment, height: 28, pointSize: 13)
    private let record = IconButton(symbols: ["record.circle"], title: "录屏", style: .segment, height: 28, pointSize: 13)

    var mode: CaptureMode = .screenshot {
        didSet { shot.isSelected = mode == .screenshot; record.isSelected = mode == .record }
    }

    override init() {
        super.init()
        shot.isSelected = true
        shot.action = { [weak self] in self?.onChange?(.screenshot) }
        record.action = { [weak self] in self?.onChange?(.record) }
        setViews([shot, record])
    }

    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - 截图工具栏

final class ScreenshotToolbar: BarView {
    var onTool: ((ToolKind) -> Void)?
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    var onOCR: (() -> Void)?
    var onTranslate: (() -> Void)?
    var onScroll: (() -> Void)?
    var onCancel: (() -> Void)?
    var onSave: (() -> Void)?
    var onConfirm: (() -> Void)?

    private var toolButtons: [ToolKind: IconButton] = [:]
    private let undoButton = IconButton(symbols: ["arrow.uturn.backward"], tooltip: "撤销")
    private let redoButton = IconButton(symbols: ["arrow.uturn.forward"], tooltip: "重做")
    private let scrollButton = IconButton(symbols: ["arrow.up.and.down.text.horizontal", "scroll", "arrow.up.and.down"], tooltip: "滚动截图")

    static let toolSymbols: [ToolKind: [String]] = [
        .rect: ["rectangle"], .ellipse: ["circle"], .arrow: ["arrow.up.right"], .line: ["line.diagonal"],
        .mosaic: ["checkerboard.rectangle", "square.grid.3x3.fill"],
        .label: ["text.bubble"], .highlight: ["highlighter"],
    ]
    static let toolGlyphs: [ToolKind: String] = [.text: "T"]

    init(showsExtras: Bool) {
        super.init()
        var views: [NSView] = []
        for tool in ToolKind.allCases {
            let b = IconButton(symbols: Self.toolSymbols[tool] ?? [], glyph: Self.toolGlyphs[tool], tooltip: tool.title)
            b.action = { [weak self] in self?.onTool?(tool) }
            toolButtons[tool] = b
            views.append(b)
        }
        views.append(SeparatorView())
        undoButton.action = { [weak self] in self?.onUndo?() }
        redoButton.action = { [weak self] in self?.onRedo?() }
        views += [undoButton, redoButton]
        if showsExtras {
            views.append(SeparatorView())
            let ocr = IconButton(symbols: ["text.viewfinder"], tooltip: "提取文字")
            ocr.action = { [weak self] in self?.onOCR?() }
            let translate = IconButton(symbols: ["translate", "character.bubble"], tooltip: "翻译")
            translate.action = { [weak self] in self?.onTranslate?() }
            scrollButton.action = { [weak self] in self?.onScroll?() }
            views += [ocr, translate, scrollButton]
        }
        views.append(SeparatorView())
        let cancel = IconButton(symbols: ["xmark"], tooltip: "退出（不保存）")
        cancel.tintColor = UIStyle.red
        cancel.action = { [weak self] in self?.onCancel?() }
        let save = IconButton(symbols: ["arrow.down.to.line"], tooltip: "下载")
        save.action = { [weak self] in self?.onSave?() }
        let confirm = IconButton(symbols: ["checkmark"], tooltip: "完成（复制到剪贴板）")
        confirm.tintColor = UIStyle.blue
        confirm.action = { [weak self] in self?.onConfirm?() }
        views += [cancel, save, confirm]
        setViews(views)
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(tool: ToolKind?, canUndo: Bool, canRedo: Bool, canScroll: Bool) {
        for (k, b) in toolButtons { b.isSelected = k == tool }
        undoButton.isEnabled = canUndo
        redoButton.isEnabled = canRedo
        scrollButton.isEnabled = canScroll
        scrollButton.tip = canScroll ? "滚动截图" : "滚动截图（画了标注后不可用）"
    }
}

// MARK: - 属性栏

final class PropertyBar: BarView {
    var onChange: (() -> Void)?
    private(set) var tool: ToolKind?

    func configure(tool: ToolKind) {
        self.tool = tool
        let prefs = Prefs.shared
        let style = prefs.style(tool)
        var views: [NSView] = []

        func levelButtons(_ kinds: [LevelButton.Kind], tips: [String]) -> [NSView] {
            kinds.enumerated().map { i, kind in
                let b = LevelButton(kind: kind, tooltip: tips[i])
                b.isSelected = style.level == i
                b.action = { [weak self] in prefs.setLevel(i, for: tool); self?.refresh() }
                return b
            }
        }

        switch tool {
        case .mosaic:
            let box = IconButton(symbols: ["rectangle.dashed"], title: "框选", tooltip: "框选马赛克", style: .segment, height: 28, pointSize: 13)
            let brush = IconButton(symbols: ["paintbrush.pointed", "paintbrush"], title: "涂抹", tooltip: "涂抹马赛克", style: .segment, height: 28, pointSize: 13)
            box.isSelected = prefs.mosaicMode == .box
            brush.isSelected = prefs.mosaicMode == .brush
            box.action = { [weak self] in prefs.mosaicMode = .box; self?.refresh() }
            brush.action = { [weak self] in prefs.mosaicMode = .brush; self?.refresh() }
            views += [box, brush]
            if prefs.mosaicMode == .brush {
                views.append(SeparatorView())
                views += levelButtons([.dot(6), .dot(10), .dot(14)], tips: ["细", "中", "粗"])
            }
        case .text, .label:
            views += levelButtons([.glyph(11), .glyph(14), .glyph(18)], tips: ["小", "中", "大"])
        default:
            views += levelButtons([.dot(4), .dot(7), .dot(10)], tips: ["细", "中", "粗"])
        }

        if tool != .mosaic {
            views.append(SeparatorView())
            for (i, color) in Palette.colors.enumerated() {
                let sw = ColorSwatch(color: color, tooltip: Palette.names[i])
                sw.isSelected = style.colorIndex == i
                sw.action = { [weak self] in prefs.setColor(i, for: tool); self?.refresh() }
                views.append(sw)
            }
        }
        setViews(views)
    }

    private func refresh() {
        if let tool { configure(tool: tool) }
        onChange?()
    }
}

// MARK: - 录制设置栏

struct RecordingOptions {
    enum Format { case mp4, gif }
    var format: Format = .mp4
    var microphone = false
    var systemAudio = false
    var showCursor = true
}

final class RecordBar: BarView {
    var onStart: ((RecordingOptions) -> Void)?
    var onCancel: (() -> Void)?
    /// 打开麦克风前请求权限，回调里告诉是否允许。
    var onRequestMicrophone: ((@escaping (Bool) -> Void) -> Void)?
    var onLayoutChange: (() -> Void)?

    private(set) var options = RecordingOptions()
    private let mp4 = IconButton(title: "视频 MP4", style: .segment, height: 28)
    private let gif = IconButton(title: "GIF", style: .segment, height: 28)
    private let mic = ToggleChip(title: "麦克风")
    private let sys = ToggleChip(title: "系统声音")
    private let cursor = ToggleChip(title: "显示鼠标")
    private let start = IconButton(symbols: ["record.circle"], title: "开始录制", style: .filled(UIStyle.red), height: 28, pointSize: 13)
    private let cancel = IconButton(symbols: ["xmark"], tooltip: "退出")

    override init() {
        super.init()
        cancel.tintColor = UIStyle.red
        mp4.action = { [weak self] in self?.options.format = .mp4; self?.rebuild() }
        gif.action = { [weak self] in self?.options.format = .gif; self?.rebuild() }
        mic.action = { [weak self] in self?.toggleMic() }
        sys.action = { [weak self] in self?.options.systemAudio.toggle(); self?.rebuild() }
        cursor.action = { [weak self] in self?.options.showCursor.toggle(); self?.rebuild() }
        start.action = { [weak self] in if let self { self.onStart?(self.options) } }
        cancel.action = { [weak self] in self?.onCancel?() }
        rebuild()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 每次打开都恢复默认：MP4、麦克风关、系统声音关、显示鼠标开。
    func reset() {
        options = RecordingOptions()
        rebuild()
    }

    private func toggleMic() {
        if options.microphone {
            options.microphone = false
            rebuild()
            return
        }
        onRequestMicrophone? { [weak self] granted in
            self?.options.microphone = granted
            self?.rebuild()
        }
    }

    private func rebuild() {
        mp4.isSelected = options.format == .mp4
        gif.isSelected = options.format == .gif
        mic.isOn = options.microphone
        sys.isOn = options.systemAudio
        cursor.isOn = options.showCursor
        var views: [NSView] = [mp4, gif, SeparatorView()]
        if options.format == .mp4 { views += [mic, sys] }
        views += [cursor, SeparatorView(), start, cancel]
        setViews(views)
        onLayoutChange?()
    }
}
