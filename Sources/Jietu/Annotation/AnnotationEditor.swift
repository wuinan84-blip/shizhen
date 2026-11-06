import AppKit

protocol AnnotationEditorHost: AnyObject {
    /// 文字输入框加到这个视图上，它的坐标系必须与编辑器坐标系一致（左上角原点）。
    var editorTextContainer: NSView { get }
    /// 可见、可画的区域（截图时就是选区）。
    var editorClipRect: CGRect { get }
    /// 只需要重绘（悬停变化等）。
    func editorNeedsDisplay()
    /// 标注内容或工具状态变了：重绘并刷新工具栏状态。
    func editorContentChanged()
}

/// 标注编辑：画新标注、移动 / 调大小 / 旋转已画标注、文字输入、撤销重做。
final class AnnotationEditor: NSObject, NSTextViewDelegate {
    weak var host: AnnotationEditorHost?
    let mosaic: MosaicSource

    private(set) var annotations: [Annotation] = []
    private var undoStack: [[Annotation]] = []
    private var redoStack: [[Annotation]] = []

    var tool: ToolKind? {
        didSet {
            guard tool != oldValue else { return }
            commitText()
            activeID = nil
            host?.editorContentChanged()
        }
    }

    private var hoveredID: UUID?
    /// 刚画完的标注：显示控制点，直到开始画下一个或点击空白处。
    private var activeID: UUID?

    private enum Drag {
        case drawing(start: CGPoint)
        case moving(index: Int, orig: Annotation, start: CGPoint)
        case resizing(index: Int, handle: Int, orig: Annotation)
        case rotating(index: Int, orig: Annotation, start: CGPoint)
        case placing(start: CGPoint)
        case swallow
    }

    private var drag: Drag?
    private var pending: Annotation?
    private var snapshotBeforeDrag: [Annotation]?

    // 文字输入
    private var textView: AnnotationTextView?
    private var textDraft: Annotation?

    init(mosaic: MosaicSource) {
        self.mosaic = mosaic
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var isEmpty: Bool { annotations.isEmpty && textDraft == nil }
    var isEditingText: Bool { textView != nil }
    var isInteracting: Bool { drag != nil }

    // MARK: 命中测试

    /// 优先级：控制点 > 旋转区域 > 图形本身；同级时上层优先。
    func hitTest(_ p: CGPoint) -> (index: Int, hit: AnnotationHit)? {
        guard let clip = host?.editorClipRect else { return nil }
        guard clip.insetBy(dx: -Annotation.handleRadius - 2, dy: -Annotation.handleRadius - 2).contains(p) else { return nil }
        for i in annotations.indices.reversed() {
            for (h, pt) in annotations[i].handles.enumerated() where hypot(p.x - pt.x, p.y - pt.y) <= Annotation.handleRadius + 2 {
                return (i, .handle(h))
            }
        }
        for i in annotations.indices.reversed() where annotations[i].canRotate && annotations[i].inRotateZone(p) {
            return (i, .rotate)
        }
        guard clip.contains(p) else { return nil }
        for i in annotations.indices.reversed() where annotations[i].hitBody(p) {
            return (i, .body)
        }
        return nil
    }

    func cursor(at p: CGPoint) -> NSCursor? {
        guard let (i, hit) = hitTest(p) else { return nil }
        switch hit {
        case .handle(let h): return Cursors.resize(angle: annotations[i].handleAngle(h))
        case .rotate: return Cursors.rotate
        case .body: return Cursors.move
        }
    }

    func updateHover(_ p: CGPoint?) {
        let id = p.flatMap { hitTest($0) }.map { annotations[$0.index].id }
        if id != hoveredID {
            hoveredID = id
            host?.editorNeedsDisplay()
        }
    }

    // MARK: 鼠标

    /// 返回 true 表示这次按下由编辑器处理；false 表示交给宿主（例如移动选区）。
    func mouseDown(at p: CGPoint) -> Bool {
        if isEditingText {
            commitText()
            return true
        }
        if let (i, hit) = hitTest(p) {
            let a = annotations[i]
            activeID = a.id
            snapshotBeforeDrag = annotations
            switch hit {
            case .handle(let h): drag = .resizing(index: i, handle: h, orig: a)
            case .rotate: drag = .rotating(index: i, orig: a, start: p)
            case .body: drag = .moving(index: i, orig: a, start: p)
            }
            host?.editorNeedsDisplay()
            return true
        }
        guard let tool, let clip = host?.editorClipRect, clip.contains(p) else {
            if activeID != nil { activeID = nil; host?.editorNeedsDisplay() }
            return false
        }
        activeID = nil
        let style = Prefs.shared.style(tool)
        if tool != .mosaic && style.colorIndex == nil {
            // 没选过颜色：什么都不画，也不提示
            drag = .swallow
            return true
        }
        if tool == .text || tool == .label {
            drag = .placing(start: p)
            return true
        }
        pending = makeAnnotation(tool, at: p)
        drag = .drawing(start: p)
        host?.editorNeedsDisplay()
        return true
    }

    func mouseDragged(to raw: CGPoint) {
        guard let drag else { return }
        switch drag {
        case .drawing(let start):
            guard var a = pending, let clip = host?.editorClipRect else { return }
            let p = CGPoint(x: min(max(raw.x, clip.minX), clip.maxX), y: min(max(raw.y, clip.minY), clip.maxY))
            if a.isBoxLike {
                let r = Geometry.rect(start, p)
                a.center = r.center
                a.size = r.size
            } else if a.isSegment {
                a.p2 = p
            } else if a.kind == .mosaicBrush {
                if let last = a.points.last, hypot(last.x - p.x, last.y - p.y) >= 1.5 { a.points.append(p) }
            }
            pending = a
        case .moving(let i, let orig, let start):
            var a = orig
            a.translate(raw.x - start.x, raw.y - start.y)
            annotations[i] = a
        case .resizing(let i, let h, let orig):
            annotations[i] = Annotation.resized(orig, handle: h, to: raw)
        case .rotating(let i, let orig, let start):
            annotations[i] = Annotation.rotated(orig, from: start, to: raw)
        case .placing, .swallow:
            break
        }
        host?.editorNeedsDisplay()
    }

    func mouseUp(at p: CGPoint) {
        guard let drag else { return }
        self.drag = nil
        switch drag {
        case .drawing:
            if let a = pending, isValidShape(a) {
                pushUndo()
                annotations.append(a)
                activeID = a.id
            }
            pending = nil
            host?.editorContentChanged()
        case .moving, .resizing, .rotating:
            if let before = snapshotBeforeDrag, before != annotations {
                undoStack.append(before)
                redoStack.removeAll()
            }
            snapshotBeforeDrag = nil
            host?.editorContentChanged()
        case .placing(let start):
            beginText(at: start)
        case .swallow:
            break
        }
    }

    private func makeAnnotation(_ tool: ToolKind, at p: CGPoint) -> Annotation {
        let kind: AnnotationKind
        switch tool {
        case .rect: kind = .rect
        case .ellipse: kind = .ellipse
        case .arrow: kind = .arrow
        case .line: kind = .line
        case .highlight: kind = .highlight
        case .mosaic: kind = Prefs.shared.mosaicMode == .box ? .mosaicBox : .mosaicBrush
        case .text: kind = .text
        case .label: kind = .label
        }
        var a = Annotation(kind: kind)
        a.colorIndex = Prefs.shared.style(tool).colorIndex ?? 0
        a.width = Prefs.shared.sizeValue(tool)
        a.center = p
        a.p1 = p
        a.p2 = p
        a.anchor = p
        if kind == .mosaicBrush { a.points = [p] }
        return a
    }

    private func isValidShape(_ a: Annotation) -> Bool {
        if a.isBoxLike { return a.size.width >= 3 && a.size.height >= 3 }
        if a.isSegment { return hypot(a.p2.x - a.p1.x, a.p2.y - a.p1.y) >= 3 }
        return true
    }

    // MARK: 文字和标签

    private func beginText(at p: CGPoint) {
        guard let tool, let host else { return }
        var a = makeAnnotation(tool, at: p)
        let tv = AnnotationTextView(frame: .zero)
        tv.delegate = self
        tv.onMarkedTextChange = { [weak self] in self?.textContentChanged() }
        tv.font = Annotation.font(a.width)
        tv.isRichText = false
        tv.drawsBackground = false
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.isHorizontallyResizable = true
        tv.isVerticallyResizable = true
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.containerSize = CGSize(width: 10000, height: 10000)
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        if a.kind == .text {
            // 点击位置作为第一行文字的垂直中心
            a.anchor = CGPoint(x: p.x - Annotation.textPadding.width,
                               y: p.y - Annotation.measure(" ", fontSize: a.width).height / 2 - Annotation.textPadding.height)
            tv.textColor = a.color
            tv.insertionPointColor = a.color
        } else {
            let clip = host.editorClipRect
            let gap = a.labelDotRadius + 8
            a.bubbleOnLeft = p.x + gap + 120 > clip.maxX && p.x - gap - 120 >= clip.minX
            tv.textColor = Annotation.bubbleTextColor(a.colorIndex)
            tv.insertionPointColor = Annotation.bubbleTextColor(a.colorIndex)
        }
        tv.typingAttributes = [.font: Annotation.font(a.width), .foregroundColor: tv.textColor ?? a.color]
        textDraft = a
        textView = tv
        host.editorTextContainer.addSubview(tv)
        layoutTextView()
        host.editorTextContainer.window?.makeFirstResponder(tv)
        host.editorContentChanged()
    }

    private func layoutTextView() {
        guard let tv = textView, var a = textDraft else { return }
        a.text = tv.string
        let m = Annotation.measure(tv.string, fontSize: a.width)
        let frame: CGRect
        if a.kind == .text {
            frame = CGRect(x: a.anchor.x + Annotation.textPadding.width, y: a.anchor.y + Annotation.textPadding.height,
                           width: m.width + 4, height: m.height)
        } else {
            let inner = a.bubbleRect.insetBy(dx: Annotation.bubblePadding.width, dy: Annotation.bubblePadding.height)
            frame = CGRect(x: inner.minX, y: inner.minY, width: max(inner.width, m.width) + 4, height: m.height)
        }
        if tv.frame != frame {
            tv.frame = frame
            // 加宽后新露出的部分也要重画，否则那里的字可能不显示
            tv.needsDisplay = true
        }
        textDraft = a
    }

    func textDidChange(_ notification: Notification) {
        textContentChanged()
    }

    private func textContentChanged() {
        layoutTextView()
        host?.editorNeedsDisplay()
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            commitText()
            return true
        }
        return false
    }

    /// 结束文字输入；内容为空时丢弃。
    func commitText() {
        guard let tv = textView, var a = textDraft else { return }
        a.text = tv.string
        textView = nil
        textDraft = nil
        let container = tv.superview
        tv.delegate = nil
        tv.removeFromSuperview()
        if !a.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if a.kind == .label, let clip = host?.editorClipRect {
                var right = a; right.bubbleOnLeft = false
                var left = a; left.bubbleOnLeft = true
                if right.bubbleRect.maxX > clip.maxX && left.bubbleRect.minX >= clip.minX { a.bubbleOnLeft = true }
                else if right.bubbleRect.maxX <= clip.maxX { a.bubbleOnLeft = false }
            }
            pushUndo()
            annotations.append(a)
            activeID = a.id
        }
        if let container { container.window?.makeFirstResponder(container) }
        host?.editorContentChanged()
    }

    // MARK: 撤销重做

    private func pushUndo() {
        undoStack.append(annotations)
        redoStack.removeAll()
    }

    func undo() {
        commitText()
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(annotations)
        annotations = prev
        activeID = nil
        host?.editorContentChanged()
    }

    func redo() {
        commitText()
        guard let next = redoStack.popLast() else { return }
        undoStack.append(annotations)
        annotations = next
        activeID = nil
        host?.editorContentChanged()
    }

    func clearAll() {
        commitText()
        annotations.removeAll()
        undoStack.removeAll()
        redoStack.removeAll()
        activeID = nil
        hoveredID = nil
        host?.editorContentChanged()
    }

    // MARK: 绘制

    /// 画所有标注（裁剪到可见区域），可选地画控制点。
    func draw(in ctx: CGContext, showHandles: Bool) {
        guard let clip = host?.editorClipRect else { return }
        ctx.saveGState()
        ctx.clip(to: clip)
        for a in annotations { AnnotationRenderer.draw(a, in: ctx, mosaic: mosaic) }
        if let pending { AnnotationRenderer.draw(pending, in: ctx, mosaic: mosaic) }
        if let draft = textDraft { drawDraft(draft, ctx: ctx) }
        ctx.restoreGState()

        guard showHandles else { return }
        ctx.saveGState()
        ctx.clip(to: clip.insetBy(dx: -8, dy: -8))
        var shown = Set<UUID>()
        for id in [activeID, hoveredID].compactMap({ $0 }) where !shown.contains(id) {
            shown.insert(id)
            if let a = annotations.first(where: { $0.id == id }) { AnnotationRenderer.drawHandles(a, in: ctx) }
        }
        if let pending, pending.isSegment || pending.isBoxLike { AnnotationRenderer.drawHandles(pending, in: ctx) }
        ctx.restoreGState()
    }

    /// 只画标注，不画控制点和输入中的文字框。用于导出和识别文字。
    func renderFinal(in ctx: CGContext) {
        guard let clip = host?.editorClipRect else { return }
        ctx.saveGState()
        ctx.clip(to: clip)
        for a in annotations { AnnotationRenderer.draw(a, in: ctx, mosaic: mosaic) }
        ctx.restoreGState()
    }

    private func drawDraft(_ a: Annotation, ctx: CGContext) {
        if a.kind == .text {
            let r = a.textRect.insetBy(dx: -1, dy: -1)
            ctx.saveGState()
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor)
            ctx.setLineWidth(1)
            ctx.setLineDash(phase: 0, lengths: [4, 3])
            ctx.stroke(r)
            ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.6).cgColor)
            ctx.setLineDash(phase: 3.5, lengths: [4, 3])
            ctx.stroke(r)
            ctx.restoreGState()
        } else {
            let r = a.labelDotRadius
            let dot = CGRect(x: a.anchor.x - r, y: a.anchor.y - r, width: r * 2, height: r * 2)
            ctx.setFillColor(a.color.cgColor)
            ctx.fillEllipse(in: dot)
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineWidth(2)
            ctx.strokeEllipse(in: dot.insetBy(dx: 1, dy: 1))
            AnnotationRenderer.drawBubble(rect: a.bubbleRect, pointingTo: a.anchor, onLeft: a.bubbleOnLeft,
                                          colorIndex: a.colorIndex, ctx: ctx)
        }
    }
}

/// 标注文字输入框。
final class AnnotationTextView: NSTextView {
    /// 输入法组字（如拼音）变化时调用：NSTextView 只在文字上屏时才发 textDidChange。
    var onMarkedTextChange: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        onMarkedTextChange?()
    }

    override func unmarkText() {
        super.unmarkText()
        onMarkedTextChange?()
    }
}
