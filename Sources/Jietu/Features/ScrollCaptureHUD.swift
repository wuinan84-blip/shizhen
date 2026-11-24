import AppKit

/// 滚动截图过程中围绕选区的浮动控件（仿飞书）：
/// 左下角 编辑 / 下载 / 取消 / 完成，正下方 自动滚动 / 停止滚动，右侧长图缩略图，选区中间提示。
/// 这些窗口不会被采集进长图（采集时排除了本应用的窗口）。
final class ScrollCaptureHUD {
    var onEdit: (() -> Void)?
    var onSave: (() -> Void)?
    var onCancel: (() -> Void)?
    var onFinish: (() -> Void)?
    var onAuto: (() -> Void)?
    /// 返回 true 表示已处理。
    var onKey: ((NSEvent) -> Bool)?

    /// 选区，屏幕坐标（左下角为原点）。
    private let selection: CGRect
    private let screen: NSScreen
    private let margin: CGFloat = 10
    private let gap: CGFloat = 8

    private let actionsBar = BarView()
    private let autoBar = BarView()
    private let startAuto = IconButton(symbols: ["play.fill"], title: "自动滚动", tooltip: "自动向下滚动并截图", height: 28, pointSize: 11)
    private let stopAuto = IconButton(symbols: ["pause.fill"], title: "停止滚动", height: 28, pointSize: 11)
    private let previewView = PreviewView()
    private let toastView = ToastView()

    private var actionsPanel: HUDPanel!
    private var autoPanel: HUDPanel!
    private var previewPanel: HUDPanel!
    private var toastPanel: HUDPanel!
    private var toastGeneration = 0

    init(selection: CGRect, screen: NSScreen) {
        self.selection = selection
        self.screen = screen

        let edit = IconButton(symbols: ["pencil"], tooltip: "编辑")
        let save = IconButton(symbols: ["arrow.down.to.line"], tooltip: "下载")
        let cancel = IconButton(symbols: ["xmark"], tooltip: "取消（回到选区）")
        cancel.tintColor = UIStyle.red
        let finish = IconButton(symbols: ["checkmark"], tooltip: "完成（复制到剪贴板）")
        finish.tintColor = UIStyle.blue
        edit.action = { [weak self] in self?.onEdit?() }
        save.action = { [weak self] in self?.onSave?() }
        cancel.action = { [weak self] in self?.onCancel?() }
        finish.action = { [weak self] in self?.onFinish?() }
        actionsBar.setViews([edit, save, cancel, finish])

        startAuto.action = { [weak self] in self?.onAuto?() }
        stopAuto.action = { [weak self] in self?.onAuto?() }
        autoBar.setViews([startAuto])

        actionsPanel = HUDPanel(content: actionsBar, margin: margin, interactive: true)
        autoPanel = HUDPanel(content: autoBar, margin: margin, interactive: true)
        previewPanel = HUDPanel(content: previewView, margin: margin, interactive: false)
        toastPanel = HUDPanel(content: toastView, margin: margin, interactive: false)
        actionsPanel.onKey = { [weak self] e in self?.onKey?(e) ?? false }
        autoPanel.onKey = actionsPanel.onKey
    }

    func show() {
        layoutButtons()
        NSApp.activate(ignoringOtherApps: true)
        autoPanel.orderFront(nil)
        actionsPanel.makeKeyAndOrderFront(nil)
    }

    func makeKey() {
        NSApp.activate(ignoringOtherApps: true)
        actionsPanel.makeKeyAndOrderFront(nil)
    }

    func close() {
        for p in [actionsPanel, autoPanel, previewPanel, toastPanel] {
            p?.orderOut(nil)
            p?.close()
        }
    }

    var autoScrolling = false {
        didSet {
            guard autoScrolling != oldValue else { return }
            autoBar.setViews([autoScrolling ? stopAuto : startAuto])
            layoutButtons()
        }
    }

    // MARK: 缩略图

    /// 缩略图最大尺寸（像素）。
    var previewPixelSize: (width: Int, height: Int) {
        let s = screen.backingScaleFactor
        return (Int(previewWidth * s), Int(selection.height * s))
    }

    private var previewWidth: CGFloat { min(180, max(100, (selection.width * 0.35).rounded())) }

    func setPreview(_ image: CGImage) {
        let s = screen.backingScaleFactor
        let size = CGSize(width: CGFloat(image.width) / s, height: CGFloat(image.height) / s)
        guard size.width > 0, size.height > 0 else { return }
        previewView.image = image
        let frame = screen.frame
        var x = selection.maxX + gap
        if x + size.width > frame.maxX - 4 { x = selection.minX - gap - size.width }
        if x < frame.minX + 4 { x = selection.maxX - size.width - gap }
        let content = CGRect(x: x, y: selection.maxY - size.height, width: size.width, height: size.height)
        previewPanel.setFrame(content.insetBy(dx: -margin, dy: -margin), display: true)
        if !previewPanel.isVisible { previewPanel.orderFront(nil) }
    }

    // MARK: 提示

    /// duration 为 nil 时一直显示，直到下一条提示或 hideToast。
    func toast(_ text: String, warning: Bool = false, duration: TimeInterval? = 3) {
        toastGeneration += 1
        let generation = toastGeneration
        toastView.set(text, warning: warning, maxWidth: max(160, min(selection.width - 24, 420)))
        let size = toastView.frame.size
        let content = CGRect(x: (selection.midX - size.width / 2).rounded(), y: (selection.midY - size.height / 2).rounded(),
                             width: size.width, height: size.height)
        toastPanel.setFrame(content.insetBy(dx: -margin, dy: -margin), display: true)
        toastPanel.orderFront(nil)
        if let duration {
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
                guard let self, self.toastGeneration == generation else { return }
                self.hideToast()
            }
        }
    }

    func hideToast() {
        toastGeneration += 1
        toastPanel.orderOut(nil)
    }

    // MARK: 布局

    /// 左下角放操作按钮、正下方放自动滚动；下方放不下时放进选区底部。
    private func layoutButtons() {
        let frame = screen.frame
        let actions = actionsBar.fittingBarSize
        let auto = autoBar.fittingBarSize
        let h = max(actions.height, auto.height)
        var y = selection.minY - gap - h
        if y < frame.minY + 4 { y = selection.minY + gap }

        var ax = selection.minX
        ax = min(max(ax, frame.minX + 4), frame.maxX - actions.width - 4)
        let actionsRect = CGRect(x: ax, y: y + (h - actions.height) / 2, width: actions.width, height: actions.height)

        var bx = (selection.midX - auto.width / 2).rounded()
        if bx < actionsRect.maxX + gap { bx = actionsRect.maxX + gap }
        bx = min(bx, frame.maxX - auto.width - 4)
        let autoRect = CGRect(x: bx, y: y + (h - auto.height) / 2, width: auto.width, height: auto.height)

        actionsPanel.setFrame(actionsRect.insetBy(dx: -margin, dy: -margin), display: true)
        autoPanel.setFrame(autoRect.insetBy(dx: -margin, dy: -margin), display: true)
    }
}

/// 无边框浮动窗口，内容四周留出阴影的位置。
private final class HUDPanel: NSPanel {
    var onKey: ((NSEvent) -> Bool)?
    private let interactive: Bool

    init(content: NSView, margin: CGFloat, interactive: Bool) {
        self.interactive = interactive
        super.init(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .capturePanel
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        ignoresMouseEvents = !interactive
        let container = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: margin),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -margin),
            content.topAnchor.constraint(equalTo: container.topAnchor, constant: margin),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -margin),
        ])
        contentView = container
    }

    override var canBecomeKey: Bool { interactive }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, onKey?(event) == true { return }
        super.sendEvent(event)
    }
}

/// 长图缩略图。
private final class PreviewView: NSView {
    var image: CGImage? {
        didSet { imageLayer.contents = image }
    }
    private let imageLayer = CALayer()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.cgColor
        layer?.cornerRadius = 4
        layer?.borderColor = NSColor.black.withAlphaComponent(0.12).cgColor
        layer?.borderWidth = 1
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.25
        layer?.shadowRadius = 6
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        layer?.masksToBounds = false
        imageLayer.contentsGravity = .resize
        imageLayer.cornerRadius = 4
        imageLayer.masksToBounds = true
        layer?.addSublayer(imageLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = bounds
        CATransaction.commit()
    }
}

/// 选区中间的深色提示。
private final class ToastView: NSView {
    private let label = NSTextField(wrappingLabelWithString: "")
    private let padding = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        label.font = NSFont.systemFont(ofSize: 13)
        label.textColor = .white
        label.alignment = .center
        label.isSelectable = false
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(_ text: String, warning: Bool, maxWidth: CGFloat) {
        layer?.backgroundColor = (warning ? UIStyle.red : NSColor.black).withAlphaComponent(0.78).cgColor
        label.stringValue = text
        let inner = maxWidth - padding.left - padding.right
        label.preferredMaxLayoutWidth = inner
        let fit = label.sizeThatFits(NSSize(width: inner, height: .greatestFiniteMagnitude))
        let size = NSSize(width: ceil(min(fit.width, inner)), height: ceil(fit.height))
        label.frame = CGRect(x: padding.left, y: padding.bottom, width: size.width, height: size.height)
        frame.size = NSSize(width: size.width + padding.left + padding.right, height: size.height + padding.top + padding.bottom)
    }
}
