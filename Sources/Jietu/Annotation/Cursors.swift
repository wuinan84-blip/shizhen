import AppKit

/// 自绘光标：四向箭头（移动）、双向箭头（调大小，可任意角度）、弧形箭头（旋转）。
enum Cursors {
    private static var resizeCache: [Int: NSCursor] = [:]

    static let move: NSCursor = {
        let image = NSImage(size: NSSize(width: 26, height: 26), flipped: false) { _ in
            let c = CGPoint(x: 13, y: 13)
            let arm: CGFloat = 9
            let path = NSBezierPath()
            path.move(to: CGPoint(x: c.x - arm + 3, y: c.y)); path.line(to: CGPoint(x: c.x + arm - 3, y: c.y))
            path.move(to: CGPoint(x: c.x, y: c.y - arm + 3)); path.line(to: CGPoint(x: c.x, y: c.y + arm - 3))
            let heads = NSBezierPath()
            for angle in [0, CGFloat.pi / 2, .pi, .pi * 1.5] {
                let tip = CGPoint(x: c.x + cos(angle) * (arm + 2), y: c.y + sin(angle) * (arm + 2))
                let base = CGPoint(x: c.x + cos(angle) * (arm - 3), y: c.y + sin(angle) * (arm - 3))
                let n = CGPoint(x: -sin(angle) * 4, y: cos(angle) * 4)
                heads.move(to: tip)
                heads.line(to: CGPoint(x: base.x + n.x, y: base.y + n.y))
                heads.line(to: CGPoint(x: base.x - n.x, y: base.y - n.y))
                heads.close()
            }
            outlined(path, heads)
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: 13, y: 13))
    }()

    static let rotate: NSCursor = {
        let image = NSImage(size: NSSize(width: 26, height: 26), flipped: false) { _ in
            let c = CGPoint(x: 13, y: 13)
            let r: CGFloat = 7
            let arc = NSBezierPath()
            arc.appendArc(withCenter: c, radius: r, startAngle: 120, endAngle: 400)
            let endAngle = CGFloat(400) * .pi / 180
            let end = CGPoint(x: c.x + cos(endAngle) * r, y: c.y + sin(endAngle) * r)
            let tangent = CGPoint(x: -sin(endAngle), y: cos(endAngle))
            let normal = CGPoint(x: cos(endAngle), y: sin(endAngle))
            let head = NSBezierPath()
            head.move(to: CGPoint(x: end.x + tangent.x * 5, y: end.y + tangent.y * 5))
            head.line(to: CGPoint(x: end.x + normal.x * 4.5, y: end.y + normal.y * 4.5))
            head.line(to: CGPoint(x: end.x - normal.x * 4.5, y: end.y - normal.y * 4.5))
            head.close()
            outlined(arc, head)
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: 13, y: 13))
    }()

    /// angle：上下翻转坐标系（y 向下）里的方向角。
    static func resize(angle: CGFloat) -> NSCursor {
        var a = angle.truncatingRemainder(dividingBy: .pi)
        if a < 0 { a += .pi }
        let key = Int((a / .pi * 24).rounded()) % 24
        if let cached = resizeCache[key] { return cached }
        let visual = -CGFloat(key) / 24 * .pi
        let image = NSImage(size: NSSize(width: 26, height: 26), flipped: false) { _ in
            let c = CGPoint(x: 13, y: 13)
            let ux = cos(visual), uy = sin(visual)
            let len: CGFloat = 10
            let shaft = NSBezierPath()
            shaft.move(to: CGPoint(x: c.x - ux * (len - 4), y: c.y - uy * (len - 4)))
            shaft.line(to: CGPoint(x: c.x + ux * (len - 4), y: c.y + uy * (len - 4)))
            let heads = NSBezierPath()
            for sign in [CGFloat(1), -1] {
                let tip = CGPoint(x: c.x + sign * ux * len, y: c.y + sign * uy * len)
                let base = CGPoint(x: c.x + sign * ux * (len - 5), y: c.y + sign * uy * (len - 5))
                heads.move(to: tip)
                heads.line(to: CGPoint(x: base.x - uy * 4.5, y: base.y + ux * 4.5))
                heads.line(to: CGPoint(x: base.x + uy * 4.5, y: base.y - ux * 4.5))
                heads.close()
            }
            outlined(shaft, heads)
            return true
        }
        let cursor = NSCursor(image: image, hotSpot: NSPoint(x: 13, y: 13))
        resizeCache[key] = cursor
        return cursor
    }

    /// 白色描边 + 黑色主体，任何背景上都看得清。
    private static func outlined(_ stroke: NSBezierPath, _ fill: NSBezierPath) {
        NSColor.white.set()
        stroke.lineWidth = 4.5
        stroke.lineCapStyle = .round
        stroke.stroke()
        fill.lineWidth = 2.5
        fill.lineJoinStyle = .round
        fill.stroke()
        fill.fill()
        NSColor.black.set()
        stroke.lineWidth = 1.8
        stroke.stroke()
        fill.fill()
    }
}
