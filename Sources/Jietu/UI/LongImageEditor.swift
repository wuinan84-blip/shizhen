import AppKit
import UniformTypeIdentifiers

/// 长图编辑窗口：滚动截图完成后在这里标注，然后叉 / 下载 / 对勾。
final class LongImageEditorController: NSObject, NSWindowDelegate, AnnotationEditorHost {
    private static var openEditors: [LongImageEditorController] = []

    private let image: CGImage
    private let scale: CGFloat
    private let window: NSWindow
    private let canvas: LongImageCanvas
    private let scrollView = NSScrollView()
    private let editor: AnnotationEditor
    private let toolbar = ScreenshotToolbar(showsExtras: false)
    private let propertyBar = PropertyBar()
    private let barArea = FlippedView()

    static func open(image: CGImage, scale: CGFloat) {
        let c = LongImageEditorController(image: image, scale: scale)
        openEditors.append(c)
        NSApp.activate(ignoringOtherApps: true)
        c.window.makeKeyAndOrderFront(nil)
        c.window.makeFirstResponder(c.canvas)
    }

    private init(image: CGImage, scale: CGFloat) {
        self.image = image
        self.scale = scale
        let size = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        canvas = LongImageCanvas(frame: CGRect(origin: .zero, size: size))
        editor = AnnotationEditor(mosaic: MosaicSource(background: image, rect: CGRect(origin: .zero, size: size)))

        let vf = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let barHeight: CGFloat = 96
        let width = min(max(size.width + 40, 560), vf.width * 0.9)
        let height = min(size.height + barHeight + 30, vf.height * 0.9)
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: height),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        window.title = "长截图 · \(image.width) × \(image.height)"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()

        editor.host = self
        canvas.image = image
        canvas.editor = editor
        canvas.onKey = { [weak self] e in self?.handleKey(e) ?? false }

        let content = FlippedView(frame: CGRect(x: 0, y: 0, width: width, height: height))
        content.autoresizingMask = [.width, .height]
        window.contentView = content

        scrollView.frame = CGRect(x: 0, y: 0, width: width, height: height - barHeight)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor(hex: 0xEFF0F1)
        let clip = CenteringClipView()
        scrollView.contentView = clip
        scrollView.documentView = canvas
        content.addSubview(scrollView)

        barArea.frame = CGRect(x: 0, y: height - barHeight, width: width, height: barHeight)
        barArea.autoresizingMask = [.width, .minYMargin]
        barArea.wantsLayer = true
        barArea.layer?.backgroundColor = NSColor(hex: 0xF5F6F7).cgColor
        content.addSubview(barArea)
        barArea.addSubview(toolbar)
        barArea.addSubview(propertyBar)
        barArea.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: barArea, queue: .main) { [weak self] _ in
            self?.layoutBars()
        }

        toolbar.onTool = { [weak self] tool in
            guard let self else { return }
            self.editor.tool = self.editor.tool == tool ? nil : tool
            if let t = self.editor.tool { self.propertyBar.configure(tool: t) }
            self.editorContentChanged()
        }
        toolbar.onUndo = { [weak self] in self?.editor.undo() }
        toolbar.onRedo = { [weak self] in self?.editor.redo() }
        toolbar.onCancel = { [weak self] in self?.window.close() }
        toolbar.onSave = { [weak self] in self?.save() }
        toolbar.onConfirm = { [weak self] in self?.confirm() }
        propertyBar.onChange = { [weak self] in self?.layoutBars() }
        editorContentChanged()
        scrollView.contentView.scroll(to: .zero)
    }

    private func layoutBars() {
        let tb = toolbar.fittingBarSize
        let y: CGFloat = 10
        toolbar.frame = CGRect(x: ((barArea.bounds.width - tb.width) / 2).rounded(), y: y, width: tb.width, height: tb.height)
        propertyBar.isHidden = editor.tool == nil
        if !propertyBar.isHidden {
            let pb = propertyBar.fittingBarSize
            propertyBar.frame = CGRect(x: toolbar.frame.minX, y: toolbar.frame.maxY + 6, width: pb.width, height: pb.height)
        }
    }

    // MARK: AnnotationEditorHost

    var editorTextContainer: NSView { canvas }
    var editorClipRect: CGRect { canvas.bounds }
    func editorNeedsDisplay() { canvas.needsDisplay = true }
    func editorContentChanged() {
        canvas.needsDisplay = true
        toolbar.update(tool: editor.tool, canUndo: editor.canUndo, canRedo: editor.canRedo, canScroll: false)
        if let t = editor.tool, propertyBar.tool != t { propertyBar.configure(tool: t) }
        layoutBars()
    }

    // MARK: 键盘

    private func handleKey(_ e: NSEvent) -> Bool {
        let prefs = Prefs.shared
        if prefs.shortcut(.cancel).matches(e) { window.close(); return true }
        if prefs.shortcut(.confirm).matches(e) { confirm(); return true }
        if prefs.shortcut(.save).matches(e) { save(); return true }
        if prefs.shortcut(.undo).matches(e) { editor.undo(); return true }
        if prefs.shortcut(.redo).matches(e) { editor.redo(); return true }
        return false
    }

    // MARK: 输出

    private func render() -> CGImage? {
        editor.commitText()
        let w = image.width, h = image.height
        let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        ctx.scaleBy(x: scale, y: scale)
        ctx.interpolationQuality = .none
        AnnotationRenderer.drawImage(image, in: canvas.bounds, ctx: ctx)
        ctx.interpolationQuality = .high
        AnnotationRenderer.withFlippedNSContext(ctx) { editor.renderFinal(in: ctx) }
        return ctx.makeImage()
    }

    private func confirm() {
        guard let img = render() else { return }
        Clipboard.writeImage(img, scale: scale)
        window.close()
    }

    private func save() {
        guard let img = render(),
              let url = SavePanel.run(defaultName: Paths.screenshotName(), type: .png) else { return }
        do {
            try ImageFile.pngData(img, scale: scale)?.write(to: url)
            window.close()
        } catch {
            Alerts.info("保存失败", info: error.localizedDescription)
        }
    }

    func windowWillClose(_ notification: Notification) {
        Self.openEditors.removeAll { $0 === self }
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// 图片比窗口小时居中显示。
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var r = super.constrainBoundsRect(proposedBounds)
        guard let doc = documentView else { return r }
        if doc.frame.width < r.width { r.origin.x = (doc.frame.width - r.width) / 2 }
        if doc.frame.height < r.height { r.origin.y = (doc.frame.height - r.height) / 2 }
        return r
    }
}

final class LongImageCanvas: NSView {
    var image: CGImage?
    weak var editor: AnnotationEditor?
    var onKey: ((NSEvent) -> Bool)?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect, .cursorUpdate], owner: self))
    }

    override func cursorUpdate(with event: NSEvent) {}

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        if let image {
            ctx.saveGState()
            ctx.clip(to: dirtyRect)
            ctx.interpolationQuality = .high
            AnnotationRenderer.drawImage(image, in: bounds, ctx: ctx)
            ctx.restoreGState()
        }
        editor?.draw(in: ctx, showHandles: true)
    }

    private func point(_ e: NSEvent) -> CGPoint { convert(e.locationInWindow, from: nil) }

    override func mouseMoved(with event: NSEvent) {
        guard let editor else { return }
        let p = point(event)
        editor.updateHover(p)
        if let c = editor.cursor(at: p) { c.set(); return }
        if let tool = editor.tool { (tool == .text ? NSCursor.iBeam : NSCursor.crosshair).set() } else { NSCursor.arrow.set() }
    }

    override func mouseDown(with event: NSEvent) { _ = editor?.mouseDown(at: point(event)) }
    override func mouseDragged(with event: NSEvent) {
        autoscroll(with: event)
        editor?.mouseDragged(to: point(event))
    }
    override func mouseUp(with event: NSEvent) { editor?.mouseUp(at: point(event)) }

    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if editor?.isEditingText == true { return super.performKeyEquivalent(with: event) }
        if !event.modifierFlags.intersection(KeyCombo.relevantModifiers).isEmpty, onKey?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}
