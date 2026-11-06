import AppKit

enum AnnotationKind {
    case rect, ellipse, arrow, line, highlight, mosaicBox, mosaicBrush, text, label
}

enum AnnotationHit: Equatable {
    case handle(Int)
    case rotate
    case body
}

/// 一个已画的标注。坐标系：左上角为原点、y 向下，单位 pt。
struct Annotation: Equatable {
    var id = UUID()
    var kind: AnnotationKind
    var colorIndex = 0
    /// 线宽 / 笔刷宽度 / 字号
    var width: CGFloat = 4

    // 矩形、椭圆、框选马赛克：中心、尺寸、旋转角（弧度）
    var center: CGPoint = .zero
    var size: CGSize = .zero
    var rotation: CGFloat = 0

    // 箭头、直线、高亮：起点、终点
    var p1: CGPoint = .zero
    var p2: CGPoint = .zero

    // 涂抹马赛克的笔迹
    var points: [CGPoint] = []

    // 文字：文字框左上角；标签：定位点
    var anchor: CGPoint = .zero
    var text = ""
    var bubbleOnLeft = false

    static let hitTolerance: CGFloat = 6
    static let handleRadius: CGFloat = 6

    var color: NSColor { Palette.color(colorIndex) }

    var isBoxLike: Bool { kind == .rect || kind == .ellipse || kind == .mosaicBox }
    var isSegment: Bool { kind == .arrow || kind == .line || kind == .highlight }
    var canRotate: Bool { kind == .rect || kind == .ellipse }

    // MARK: 坐标变换

    func toLocal(_ p: CGPoint) -> CGPoint {
        let d = CGPoint(x: p.x - center.x, y: p.y - center.y)
        let c = cos(-rotation), s = sin(-rotation)
        return CGPoint(x: d.x * c - d.y * s, y: d.x * s + d.y * c)
    }

    func toWorld(_ q: CGPoint) -> CGPoint {
        let c = cos(rotation), s = sin(rotation)
        return CGPoint(x: center.x + q.x * c - q.y * s, y: center.y + q.x * s + q.y * c)
    }

    mutating func translate(_ dx: CGFloat, _ dy: CGFloat) {
        center.x += dx; center.y += dy
        p1.x += dx; p1.y += dy
        p2.x += dx; p2.y += dy
        anchor.x += dx; anchor.y += dy
        points = points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
    }

    // MARK: 文字布局

    static func font(_ size: CGFloat) -> NSFont { NSFont.systemFont(ofSize: size, weight: .medium) }

    static func textAttributes(size: CGFloat, color: NSColor) -> [NSAttributedString.Key: Any] {
        [.font: font(size), .foregroundColor: color]
    }

    /// 文字内容（加上内边距）所占的尺寸。
    static func measure(_ text: String, fontSize: CGFloat) -> CGSize {
        let s = text.isEmpty ? " " : text
        let r = (s as NSString).boundingRect(with: CGSize(width: 10000, height: 10000),
                                              options: [.usesLineFragmentOrigin, .usesFontLeading],
                                              attributes: [.font: font(fontSize)])
        return CGSize(width: ceil(r.width), height: ceil(r.height))
    }

    static let textPadding = CGSize(width: 4, height: 2)
    static let bubblePadding = CGSize(width: 8, height: 5)

    var labelDotRadius: CGFloat { max(5, width * 0.32) }

    var textRect: CGRect {
        let m = Annotation.measure(text, fontSize: width)
        return CGRect(x: anchor.x, y: anchor.y,
                      width: m.width + Annotation.textPadding.width * 2,
                      height: m.height + Annotation.textPadding.height * 2)
    }

    static func bubbleSize(text: String, fontSize: CGFloat) -> CGSize {
        let m = measure(text, fontSize: fontSize)
        return CGSize(width: max(m.width, fontSize) + bubblePadding.width * 2, height: m.height + bubblePadding.height * 2)
    }

    var bubbleRect: CGRect {
        let size = Annotation.bubbleSize(text: text, fontSize: width)
        let gap = labelDotRadius + 8
        let x = bubbleOnLeft ? anchor.x - gap - size.width : anchor.x + gap
        return CGRect(x: x, y: anchor.y - size.height / 2, width: size.width, height: size.height)
    }

    /// 标签气泡里的文字颜色：浅色气泡用深色字。
    static func bubbleTextColor(_ colorIndex: Int) -> NSColor {
        (colorIndex == 1 || colorIndex == 5) ? NSColor(hex: 0x1F2329) : .white
    }

    // MARK: 包围盒

    var bounds: CGRect {
        switch kind {
        case .rect, .ellipse, .mosaicBox:
            let corners = [CGPoint(x: -size.width / 2, y: -size.height / 2), CGPoint(x: size.width / 2, y: -size.height / 2),
                           CGPoint(x: size.width / 2, y: size.height / 2), CGPoint(x: -size.width / 2, y: size.height / 2)].map(toWorld)
            return CGRect.boundingBox(corners).insetBy(dx: -width, dy: -width)
        case .arrow, .line, .highlight:
            return CGRect.boundingBox([p1, p2]).insetBy(dx: -width * 3, dy: -width * 3)
        case .mosaicBrush:
            return CGRect.boundingBox(points).insetBy(dx: -width, dy: -width)
        case .text:
            return textRect
        case .label:
            let dot = CGRect(x: anchor.x - labelDotRadius, y: anchor.y - labelDotRadius,
                             width: labelDotRadius * 2, height: labelDotRadius * 2)
            return dot.union(bubbleRect)
        }
    }

    // MARK: 控制点

    /// 控制点的位置。矩形类为四条边中点（上、右、下、左），线段类为两端。
    var handles: [CGPoint] {
        if isBoxLike {
            let w = size.width / 2, h = size.height / 2
            return [CGPoint(x: 0, y: -h), CGPoint(x: w, y: 0), CGPoint(x: 0, y: h), CGPoint(x: -w, y: 0)].map(toWorld)
        }
        if isSegment { return [p1, p2] }
        return []
    }

    /// 控制点所在边的法线方向（用于显示双向箭头光标）。
    func handleAngle(_ index: Int) -> CGFloat {
        if isBoxLike { return rotation + (index % 2 == 0 ? .pi / 2 : 0) }
        return atan2(p2.y - p1.y, p2.x - p1.x)
    }

    // MARK: 命中测试

    func hitTest(_ p: CGPoint) -> AnnotationHit? {
        for (i, h) in handles.enumerated() where hypot(p.x - h.x, p.y - h.y) <= Annotation.handleRadius + 2 {
            return .handle(i)
        }
        if canRotate && inRotateZone(p) { return .rotate }
        if hitBody(p) { return .body }
        return nil
    }

    func inRotateZone(_ p: CGPoint) -> Bool {
        let q = toLocal(p)
        let w = size.width / 2, h = size.height / 2
        let outside = abs(q.x) > w + 2 || abs(q.y) > h + 2
        guard outside else { return false }
        for c in [CGPoint(x: -w, y: -h), CGPoint(x: w, y: -h), CGPoint(x: w, y: h), CGPoint(x: -w, y: h)] {
            if hypot(q.x - c.x, q.y - c.y) <= 22 { return true }
        }
        return false
    }

    func hitBody(_ p: CGPoint) -> Bool {
        let tol = Annotation.hitTolerance
        switch kind {
        case .rect:
            let q = toLocal(p)
            let t = tol + width / 2
            let w = size.width / 2, h = size.height / 2
            let outer = abs(q.x) <= w + t && abs(q.y) <= h + t
            let inner = abs(q.x) < w - t && abs(q.y) < h - t
            return outer && !inner
        case .ellipse:
            let q = toLocal(p)
            let a = max(size.width / 2, 1), b = max(size.height / 2, 1)
            let v = sqrt((q.x / a) * (q.x / a) + (q.y / b) * (q.y / b))
            let r = hypot(q.x, q.y)
            let dist = v < 0.0001 ? min(a, b) : abs(r - r / v)
            return dist <= tol + width / 2
        case .arrow, .line, .highlight:
            return Geometry.distance(p, toSegment: p1, p2) <= tol + width / 2
        case .mosaicBox:
            let q = toLocal(p)
            return abs(q.x) <= size.width / 2 + tol && abs(q.y) <= size.height / 2 + tol
        case .mosaicBrush:
            if points.count == 1 { return hypot(p.x - points[0].x, p.y - points[0].y) <= width / 2 + tol }
            for i in 1..<max(points.count, 1) where Geometry.distance(p, toSegment: points[i - 1], points[i]) <= width / 2 + tol {
                return true
            }
            return false
        case .text:
            return textRect.insetBy(dx: -tol, dy: -tol).contains(p)
        case .label:
            if hypot(p.x - anchor.x, p.y - anchor.y) <= labelDotRadius + tol { return true }
            return bubbleRect.insetBy(dx: -2, dy: -2).contains(p)
        }
    }

    // MARK: 调整

    static let minSize: CGFloat = 4

    /// 拖动第 index 个控制点到 p（基于拖动开始时的原始标注 orig）。
    static func resized(_ orig: Annotation, handle index: Int, to p: CGPoint) -> Annotation {
        var a = orig
        if orig.isSegment {
            if index == 0 { a.p1 = p } else { a.p2 = p }
            return a
        }
        guard orig.isBoxLike else { return a }
        let q = orig.toLocal(p)
        var left = -orig.size.width / 2, right = orig.size.width / 2
        var top = -orig.size.height / 2, bottom = orig.size.height / 2
        switch index {
        case 0: top = min(q.y, bottom - minSize)
        case 1: right = max(q.x, left + minSize)
        case 2: bottom = max(q.y, top + minSize)
        default: left = min(q.x, right - minSize)
        }
        a.size = CGSize(width: right - left, height: bottom - top)
        a.center = orig.toWorld(CGPoint(x: (left + right) / 2, y: (top + bottom) / 2))
        return a
    }

    static func rotated(_ orig: Annotation, from start: CGPoint, to p: CGPoint) -> Annotation {
        var a = orig
        let a0 = atan2(start.y - orig.center.y, start.x - orig.center.x)
        let a1 = atan2(p.y - orig.center.y, p.x - orig.center.x)
        a.rotation = orig.rotation + (a1 - a0)
        return a
    }
}

enum Geometry {
    static func distance(_ p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        if len2 < 0.0001 { return hypot(p.x - a.x, p.y - a.y) }
        var t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2
        t = max(0, min(1, t))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    static func rect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}

extension CGRect {
    static func boundingBox(_ pts: [CGPoint]) -> CGRect {
        guard let first = pts.first else { return .zero }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in pts {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    var center: CGPoint { CGPoint(x: midX, y: midY) }

    /// 对齐到像素网格。
    func pixelAligned(scale: CGFloat) -> CGRect {
        let x0 = (minX * scale).rounded() / scale, y0 = (minY * scale).rounded() / scale
        let x1 = (maxX * scale).rounded() / scale, y1 = (maxY * scale).rounded() / scale
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
}
