import AppKit

protocol OverlayViewDelegate: AnyObject {
    func overlayCancel()
    func overlayConfirm()
    func overlaySave()
    func overlayRecognizeText(translate: Bool)
    func overlayScrollCapture()
    func overlayStartRecording(_ options: RecordingOptions)
    func overlayCancelCountdown()
    func overlayRequestMicrophone(_ completion: @escaping (Bool) -> Void)
    func overlayConfirmModeSwitch() -> Bool
}

/// 截图 / 录屏的选区界面。坐标系：左上角为原点，单位 pt，范围是整个显示器。
final class OverlayView: NSView, AnnotationEditorHost {
    weak var delegate: OverlayViewDelegate?

    let screenImage: CGImage
    let scale: CGFloat
    let editor: AnnotationEditor
    private let windowRects: [CGRect]
    private let safeTop: CGFloat

    enum Phase { case hovering, creating, selected }

    private(set) var mode: CaptureMode = .screenshot
    private(set) var phase: Phase = .hovering
    private(set) var selection: CGRect = .zero
    private(set) var isLocked = false
    private(set) var isLive = false
    private var hoverRect: CGRect?
    private var createStart: CGPoint = .zero

    private enum SelectionDrag {
        case move(orig: CGRect, start: CGPoint)
        case resize(handle: Int, orig: CGRect)
    }

    private var selectionDrag: SelectionDrag?
    private var editorOwnsDrag = false

    private let backgroundView = PassiveImageView()
    private let maskView = DimMaskView()
    private let hoverBorder = PassiveView()
    private let canvas = SelectionCanvas()
    private let sizeLabel = SizeLabel()
    private let countdownLabel = CountdownView()
    let modeBar = ModeBar()
    let toolbar = ScreenshotToolbar(showsExtras: true)
    let propertyBar = PropertyBar()
    let recordBar = RecordBar()

    init(frame: CGRect, screenImage: CGImage, scale: CGFloat, windowRects: [CGRect], safeTop: CGFloat) {
        self.screenImage = screenImage
        self.scale = scale
        self.windowRects = windowRects
        self.safeTop = safeTop
        self.editor = AnnotationEditor(mosaic: MosaicSource(background: screenImage, rect: CGRect(origin: .zero, size: frame.size)))
        super.init(frame: frame)
        wantsLayer = true
        editor.host = self
        canvas.overlay = self

        backgroundView.frame = bounds
        backgroundView.autoresizingMask = [.width, .height]
        backgroundView.image = screenImage
        maskView.frame = bounds
        maskView.autoresizingMask = [.width, .height]
        hoverBorder.wantsLayer = true
        hoverBorder.layer?.borderColor = AnnotationRenderer.selectionBlue.cgColor
        hoverBorder.layer?.borderWidth = 2
        hoverBorder.isHidden = true

        for v in [backgroundView, maskView, hoverBorder, canvas, sizeLabel, countdownLabel] as [NSView] { addSubview(v) }
        for v in [modeBar, toolbar, propertyBar, recordBar] as [NSView] { addSubview(v) }
        countdownLabel.isHidden = true
        toolbar.isHidden = true
        propertyBar.isHidden = true
        recordBar.isHidden = true
        wireBars()
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate], owner: self))
    }

    override func cursorUpdate(with event: NSEvent) {}

    // MARK: 工具栏

    private func wireBars() {
        modeBar.onChange = { [weak self] m in self?.switchMode(m) }
        toolbar.onTool = { [weak self] tool in
            guard let self else { return }
            self.editor.tool = self.editor.tool == tool ? nil : tool
            if let t = self.editor.tool { self.propertyBar.configure(tool: t) }
            self.editorContentChanged()
        }
        toolbar.onUndo = { [weak self] in self?.editor.undo() }
        toolbar.onRedo = { [weak self] in self?.editor.redo() }
        toolbar.onOCR = { [weak self] in self?.delegate?.overlayRecognizeText(translate: false) }
        toolbar.onTranslate = { [weak self] in self?.delegate?.overlayRecognizeText(translate: true) }
        toolbar.onScroll = { [weak self] in self?.delegate?.overlayScrollCapture() }
        toolbar.onCancel = { [weak self] in self?.delegate?.overlayCancel() }
        toolbar.onSave = { [weak self] in self?.delegate?.overlaySave() }
        toolbar.onConfirm = { [weak self] in self?.delegate?.overlayConfirm() }
        propertyBar.onChange = { [weak self] in self?.layoutBars() }
        recordBar.onStart = { [weak self] opts in self?.delegate?.overlayStartRecording(opts) }
        recordBar.onCancel = { [weak self] in self?.delegate?.overlayCancel() }
        recordBar.onRequestMicrophone = { [weak self] done in self?.delegate?.overlayRequestMicrophone(done) }
        recordBar.onLayoutChange = { [weak self] in self?.layoutBars() }
    }

    func setMode(_ m: CaptureMode) {
        mode = m
        modeBar.mode = m
        if m == .record {
            editor.tool = nil
            recordBar.reset()
        }
        refresh()
    }

    private func switchMode(_ m: CaptureMode) {
        guard m != mode else { return }
        if m == .record {
            editor.commitText()
            if !editor.annotations.isEmpty {
                guard delegate?.overlayConfirmModeSwitch() == true else { modeBar.mode = mode; return }
                editor.clearAll()
            }
        }
        setMode(m)
        window?.makeFirstResponder(self)
    }

    private func layoutBars() {
        let barsVisible = phase == .selected && !isLocked && !isLive
        let mb = modeBar.fittingBarSize
        modeBar.frame = CGRect(x: ((bounds.width - mb.width) / 2).rounded(), y: safeTop + 10, width: mb.width, height: mb.height)
        modeBar.isHidden = isLocked || isLive

        let showToolbar = barsVisible && mode == .screenshot
        let showProps = showToolbar && editor.tool != nil
        let showRecord = barsVisible && mode == .record
        toolbar.isHidden = !showToolbar
        propertyBar.isHidden = !showProps
        recordBar.isHidden = !showRecord
        guard barsVisible else { return }

        let gap: CGFloat = 8
        let main: NSSize = mode == .screenshot ? toolbar.fittingBarSize : recordBar.fittingBarSize
        let props: NSSize = showProps ? propertyBar.fittingBarSize : .zero
        let total = main.height + (showProps ? props.height + 6 : 0)

        var y: CGFloat
        if selection.maxY + gap + total <= bounds.maxY - 4 {
            y = selection.maxY + gap
        } else if selection.minY - gap - total >= 4 {
            y = selection.minY - gap - total
        } else {
            y = selection.maxY - gap - total
        }
        var x = selection.maxX - main.width
        x = min(max(x, 4), bounds.width - main.width - 4)
        let mainFrame = CGRect(x: x.rounded(), y: y.rounded(), width: main.width, height: main.height)
        if mode == .screenshot { toolbar.frame = mainFrame } else { recordBar.frame = mainFrame }
        if showProps {
            var px = x
            px = min(max(px, 4), bounds.width - props.width - 4)
            propertyBar.frame = CGRect(x: px.rounded(), y: (y + main.height + 6).rounded(), width: props.width, height: props.height)
        }
    }

    private var barViews: [NSView] { [modeBar, toolbar, propertyBar, recordBar] }

    private func barContains(_ p: CGPoint) -> Bool {
        barViews.contains { !$0.isHidden && $0.frame.contains(p) }
    }

    // MARK: 状态刷新

    private func refresh() {
        let hole: CGRect? = phase == .hovering ? hoverRect : (selection.isEmpty ? nil : selection)
        maskView.hole = hole
        if phase == .hovering, let r = hoverRect {
            hoverBorder.isHidden = false
            hoverBorder.frame = r.insetBy(dx: -1, dy: -1).intersection(bounds)
        } else {
            hoverBorder.isHidden = true
        }
        if phase != .hovering && !selection.isEmpty {
            canvas.isHidden = false
            canvas.frame = selection.insetBy(dx: -12, dy: -12)
            canvas.needsDisplay = true
        } else {
            canvas.isHidden = true
        }
        updateSizeLabel(hole)
        toolbar.update(tool: editor.tool, canUndo: editor.canUndo, canRedo: editor.canRedo,
                       canScroll: editor.isEmpty)
        layoutBars()
    }

    private func updateSizeLabel(_ rect: CGRect?) {
        guard let rect, !isLive else { sizeLabel.isHidden = true; return }
        sizeLabel.isHidden = false
        sizeLabel.text = "\(Int((rect.width * scale).rounded())) × \(Int((rect.height * scale).rounded()))"
        let s = sizeLabel.fittingSize
        var origin = CGPoint(x: rect.minX, y: rect.minY - s.height - 4)
        if origin.y < 2 { origin = CGPoint(x: rect.minX + 4, y: rect.minY + 4) }
        origin.x = min(max(origin.x, 2), bounds.width - s.width - 2)
        sizeLabel.frame = CGRect(origin: origin, size: s)
    }

    // MARK: AnnotationEditorHost

    var editorTextContainer: NSView { self }
    var editorClipRect: CGRect { selection }
    func editorNeedsDisplay() { canvas.needsDisplay = true }
    func editorContentChanged() {
        canvas.needsDisplay = true
        toolbar.update(tool: editor.tool, canUndo: editor.canUndo, canRedo: editor.canRedo, canScroll: editor.isEmpty)
        if let t = editor.tool, propertyBar.tool != t { propertyBar.configure(tool: t) }
        layoutBars()
    }

    // MARK: 选区控制点

    private func handlePoints(_ r: CGRect) -> [CGPoint] {
        [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
         CGPoint(x: r.maxX, y: r.midY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.midX, y: r.maxY),
         CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.minX, y: r.midY)]
    }

    private func selectionHandle(at p: CGPoint) -> Int? {
        guard phase == .selected, !isLocked, !isLive else { return nil }
        for (i, h) in handlePoints(selection).enumerated() where abs(p.x - h.x) <= 7 && abs(p.y - h.y) <= 7 {
            return i
        }
        return nil
    }

    private func handleAngle(_ i: Int) -> CGFloat {
        switch i {
        case 0, 4: return .pi / 4
        case 2, 6: return -.pi / 4
        case 1, 5: return .pi / 2
        default: return 0
        }
    }

    // MARK: 鼠标

    private func point(_ e: NSEvent) -> CGPoint { convert(e.locationInWindow, from: nil) }

    private func clamp(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, 0), bounds.width), y: min(max(p.y, 0), bounds.height))
    }

    func updateHover(at p: CGPoint) {
        guard phase == .hovering else { return }
        let r = windowRects.first(where: { $0.contains(p) }) ?? bounds
        if r != hoverRect {
            hoverRect = r
            refresh()
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let p = point(event)
        switch phase {
        case .hovering:
            updateHover(at: p)
            NSCursor.crosshair.set()
        case .creating:
            NSCursor.crosshair.set()
        case .selected:
            updateCursor(p)
        }
    }

    private func updateCursor(_ p: CGPoint) {
        if isLive { NSCursor.arrow.set(); return }
        if barContains(p) || (editor.isEditingText && subviews.contains(where: { $0 is AnnotationTextView && $0.frame.contains(p) })) {
            editor.updateHover(nil)
            (barContains(p) ? NSCursor.arrow : NSCursor.iBeam).set()
            return
        }
        let annotationHit = mode == .screenshot ? editor.hitTest(p) : nil
        if mode == .screenshot { editor.updateHover(p) }
        if let hit = annotationHit, case .handle = hit.hit, let c = editor.cursor(at: p) { c.set(); return }
        if let h = selectionHandle(at: p) { Cursors.resize(angle: handleAngle(h)).set(); return }
        if annotationHit != nil, let c = editor.cursor(at: p) { c.set(); return }
        if selection.contains(p) {
            if mode == .screenshot, let tool = editor.tool {
                (tool == .text ? NSCursor.iBeam : NSCursor.crosshair).set()
            } else if !isLocked {
                Cursors.move.set()
            } else {
                NSCursor.arrow.set()
            }
        } else {
            NSCursor.arrow.set()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = point(event)
        switch phase {
        case .hovering:
            createStart = clamp(p)
            selection = .zero
            phase = .creating
        case .creating:
            break
        case .selected:
            guard !isLive else { return }
            if mode == .screenshot && editor.isEditingText {
                _ = editor.mouseDown(at: p)
                return
            }
            let annotationHit = mode == .screenshot ? editor.hitTest(p) : nil
            if let hit = annotationHit, case .handle = hit.hit {
                editorOwnsDrag = editor.mouseDown(at: p)
                return
            }
            if let h = selectionHandle(at: p) {
                selectionDrag = .resize(handle: h, orig: selection)
                return
            }
            if mode == .screenshot && editor.mouseDown(at: p) {
                editorOwnsDrag = true
                return
            }
            if !isLocked && selection.contains(p) && (mode == .record || editor.tool == nil) {
                selectionDrag = .move(orig: selection, start: p)
            }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = point(event)
        switch phase {
        case .hovering:
            break
        case .creating:
            let c = clamp(p)
            if !selection.isEmpty || hypot(c.x - createStart.x, c.y - createStart.y) >= 4 {
                selection = Geometry.rect(createStart, c)
                hoverRect = nil
                refresh()
            }
        case .selected:
            if editorOwnsDrag {
                editor.mouseDragged(to: p)
                return
            }
            guard let drag = selectionDrag else { return }
            switch drag {
            case .move(let orig, let start):
                var dx = p.x - start.x, dy = p.y - start.y
                dx = min(max(dx, -orig.minX), bounds.width - orig.maxX)
                dy = min(max(dy, -orig.minY), bounds.height - orig.maxY)
                selection = orig.offsetBy(dx: dx, dy: dy)
            case .resize(let h, let orig):
                let c = clamp(p)
                var left = orig.minX, right = orig.maxX, top = orig.minY, bottom = orig.maxY
                if [0, 6, 7].contains(h) { left = c.x }
                if [2, 3, 4].contains(h) { right = c.x }
                if [0, 1, 2].contains(h) { top = c.y }
                if [4, 5, 6].contains(h) { bottom = c.y }
                var r = Geometry.rect(CGPoint(x: left, y: top), CGPoint(x: right, y: bottom))
                r.size.width = max(r.width, 2)
                r.size.height = max(r.height, 2)
                selection = r
            }
            refresh()
        }
    }

    override func mouseUp(with event: NSEvent) {
        let p = point(event)
        switch phase {
        case .hovering:
            break
        case .creating:
            if selection.width < 4 || selection.height < 4 {
                selection = hoverRect ?? windowRects.first(where: { $0.contains(p) }) ?? bounds
            }
            selection = selection.pixelAligned(scale: scale).intersection(bounds)
            hoverRect = nil
            phase = .selected
            refresh()
            updateCursor(p)
        case .selected:
            if editorOwnsDrag {
                editor.mouseUp(at: p)
                editorOwnsDrag = false
            }
            if selectionDrag != nil {
                selectionDrag = nil
                selection = selection.pixelAligned(scale: scale)
                refresh()
            }
        }
    }

    // MARK: 键盘

    override func keyDown(with event: NSEvent) {
        if !handleShortcut(event) { super.keyDown(with: event) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if editor.isEditingText { return super.performKeyEquivalent(with: event) }
        if event.modifierFlags.intersection(KeyCombo.relevantModifiers).isEmpty { return super.performKeyEquivalent(with: event) }
        return handleShortcut(event) || super.performKeyEquivalent(with: event)
    }

    private func handleShortcut(_ e: NSEvent) -> Bool {
        let prefs = Prefs.shared
        if isLocked {
            if prefs.shortcut(.cancelCountdown).matches(e) { delegate?.overlayCancelCountdown() }
            return true
        }
        if isLive { return true }
        if prefs.shortcut(.cancel).matches(e) { delegate?.overlayCancel(); return true }
        guard phase == .selected, mode == .screenshot else { return false }
        if prefs.shortcut(.confirm).matches(e) { delegate?.overlayConfirm(); return true }
        if prefs.shortcut(.save).matches(e) { delegate?.overlaySave(); return true }
        if prefs.shortcut(.undo).matches(e) { editor.undo(); return true }
        if prefs.shortcut(.redo).matches(e) { editor.redo(); return true }
        return false
    }

    // MARK: 倒计时、实时模式

    /// 实时模式：不显示冻结画面，只保留选区外的遮罩和边框（倒计时、滚动截图时）。
    func setLive(_ live: Bool, locked: Bool) {
        isLive = live
        isLocked = locked
        backgroundView.isHidden = live
        editor.updateHover(nil)
        refresh()
    }

    func showCountdown(_ n: Int?) {
        guard let n else { countdownLabel.isHidden = true; return }
        countdownLabel.isHidden = false
        countdownLabel.text = "\(n)"
        let side: CGFloat = 120
        countdownLabel.frame = CGRect(x: selection.midX - side / 2, y: selection.midY - side / 2, width: side, height: side)
        countdownLabel.needsDisplay = true
    }

    // MARK: 输出

    /// 把选区内的画面（含标注）渲染成实际像素的图片。
    func renderSelection() -> CGImage? {
        editor.commitText()
        let sel = selection.pixelAligned(scale: scale)
        let w = Int((sel.width * scale).rounded()), h = Int((sel.height * scale).rounded())
        guard w > 0, h > 0 else { return nil }
        let space = screenImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: info)
            ?? CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -sel.minX, y: -sel.minY)
        ctx.interpolationQuality = .none
        AnnotationRenderer.drawImage(screenImage, in: bounds, ctx: ctx)
        ctx.interpolationQuality = .high
        AnnotationRenderer.withFlippedNSContext(ctx) { editor.renderFinal(in: ctx) }
        return ctx.makeImage()
    }

    /// 选区在全局（Cocoa，左下角原点）坐标系中的位置。
    func selectionInScreen() -> CGRect {
        guard let window else { return selection }
        let inWindow = convert(selection, to: nil)
        return window.convertToScreen(inWindow)
    }

    // MARK: 绘制（由 SelectionCanvas 调用）

    fileprivate func drawCanvas(in ctx: CGContext) {
        if mode == .screenshot && !isLive { editor.draw(in: ctx, showHandles: !isLocked) }
        let r = selection
        ctx.setStrokeColor(AnnotationRenderer.selectionBlue.cgColor)
        ctx.setLineWidth(isLive ? 2 : 1.5)
        ctx.stroke(r.insetBy(dx: isLive ? -1 : -0.75, dy: isLive ? -1 : -0.75))
        guard phase == .selected, !isLocked, !isLive else { return }
        for p in handlePoints(r) {
            let hr = CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(hr)
            ctx.setStrokeColor(AnnotationRenderer.selectionBlue.cgColor)
            ctx.setLineWidth(1.5)
            ctx.stroke(hr)
        }
    }
}

// MARK: - 子视图

/// 不接收鼠标事件的视图。
class PassiveView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class PassiveImageView: PassiveView {
    var image: CGImage? { didSet { needsDisplay = true } }
    override var wantsUpdateLayer: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }
    required init?(coder: NSCoder) { fatalError() }
    override func updateLayer() {
        layer?.contents = image
        layer?.contentsGravity = .resize
    }
}

/// 选区外的半透明遮罩，由四条色带拼成（只改 frame，不重绘整屏）。
final class DimMaskView: PassiveView {
    private let bands = (0..<4).map { _ in NSView() }
    var hole: CGRect? { didSet { needsLayout = true; layoutBands() } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        for b in bands {
            b.wantsLayer = true
            b.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor
            addSubview(b)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        layoutBands()
    }

    private func layoutBands() {
        guard let h = hole?.intersection(bounds), !h.isNull, !h.isEmpty else {
            bands[0].frame = bounds
            for b in bands.dropFirst() { b.frame = .zero }
            return
        }
        bands[0].frame = CGRect(x: 0, y: 0, width: bounds.width, height: h.minY)
        bands[1].frame = CGRect(x: 0, y: h.maxY, width: bounds.width, height: bounds.height - h.maxY)
        bands[2].frame = CGRect(x: 0, y: h.minY, width: h.minX, height: h.height)
        bands[3].frame = CGRect(x: h.maxX, y: h.minY, width: bounds.width - h.maxX, height: h.height)
    }
}

final class SelectionCanvas: PassiveView {
    weak var overlay: OverlayView?
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, let overlay else { return }
        ctx.translateBy(x: -frame.minX, y: -frame.minY)
        overlay.drawCanvas(in: ctx)
    }
}

final class SizeLabel: PassiveView {
    var text = "" { didSet { needsDisplay = true } }
    private let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white,
    ]

    override var fittingSize: NSSize {
        let s = (text as NSString).size(withAttributes: attrs)
        return NSSize(width: ceil(s.width) + 12, height: ceil(s.height) + 6)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
        (text as NSString).draw(at: NSPoint(x: 6, y: 3), withAttributes: attrs)
    }
}

final class CountdownView: PassiveView {
    var text = ""

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(ovalIn: bounds).fill()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 64, weight: .semibold), .foregroundColor: NSColor.white,
        ]
        let s = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(at: NSPoint(x: bounds.midX - s.width / 2, y: bounds.midY - s.height / 2), withAttributes: attrs)
    }
}
