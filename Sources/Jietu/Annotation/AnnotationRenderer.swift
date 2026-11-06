import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// 马赛克取样：背景图打码后的版本，以及它在画布坐标里的位置。
final class MosaicSource {
    let background: CGImage
    let rect: CGRect
    private var cached: CGImage?

    init(background: CGImage, rect: CGRect) {
        self.background = background
        self.rect = rect
    }

    var pixelated: CGImage? {
        if let cached { return cached }
        let pixelsPerPoint = CGFloat(background.width) / max(rect.width, 1)
        let input = CIImage(cgImage: background)
        let filter = CIFilter.pixellate()
        filter.inputImage = input.clampedToExtent()
        filter.scale = Float(10 * pixelsPerPoint)
        filter.center = .zero
        guard let output = filter.outputImage?.cropped(to: input.extent) else { return nil }
        let context = CIContext(options: [.useSoftwareRenderer: false])
        cached = context.createCGImage(output, from: input.extent, format: .BGRA8,
                                       colorSpace: background.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB))
        return cached
    }
}

enum AnnotationRenderer {
    static let selectionBlue = NSColor(hex: 0x3370FF)

    /// 在左上角为原点的上下翻转坐标系里正确画出 CGImage。
    static func drawImage(_ image: CGImage, in rect: CGRect, ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(origin: .zero, size: rect.size))
        ctx.restoreGState()
    }

    static func draw(_ a: Annotation, in ctx: CGContext, mosaic: MosaicSource?) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        let color = a.color.cgColor
        switch a.kind {
        case .rect, .ellipse:
            ctx.translateBy(x: a.center.x, y: a.center.y)
            ctx.rotate(by: a.rotation)
            let r = CGRect(x: -a.size.width / 2, y: -a.size.height / 2, width: a.size.width, height: a.size.height)
            ctx.setStrokeColor(color)
            ctx.setLineWidth(a.width)
            ctx.setLineJoin(.round)
            if a.kind == .rect { ctx.stroke(r) } else { ctx.strokeEllipse(in: r) }

        case .line:
            ctx.setStrokeColor(color)
            ctx.setLineWidth(a.width)
            ctx.setLineCap(.round)
            ctx.move(to: a.p1); ctx.addLine(to: a.p2)
            ctx.strokePath()

        case .highlight:
            ctx.setStrokeColor(a.color.withAlphaComponent(0.4).cgColor)
            ctx.setLineWidth(a.width)
            ctx.setLineCap(.butt)
            ctx.move(to: a.p1); ctx.addLine(to: a.p2)
            ctx.strokePath()

        case .arrow:
            drawArrow(a, ctx: ctx, color: color)

        case .mosaicBox:
            guard let mosaic, let img = mosaic.pixelated else { return }
            let r = CGRect(x: a.center.x - a.size.width / 2, y: a.center.y - a.size.height / 2,
                           width: a.size.width, height: a.size.height)
            ctx.clip(to: r)
            ctx.interpolationQuality = .none
            drawImage(img, in: mosaic.rect, ctx: ctx)

        case .mosaicBrush:
            guard let mosaic, let img = mosaic.pixelated, let first = a.points.first else { return }
            let path = CGMutablePath()
            if a.points.count == 1 {
                path.addEllipse(in: CGRect(x: first.x - a.width / 2, y: first.y - a.width / 2, width: a.width, height: a.width))
            } else {
                let line = CGMutablePath()
                line.addLines(between: a.points)
                path.addPath(line.copy(strokingWithWidth: a.width, lineCap: .round, lineJoin: .round, miterLimit: 10))
            }
            ctx.addPath(path)
            ctx.clip()
            ctx.interpolationQuality = .none
            drawImage(img, in: mosaic.rect, ctx: ctx)

        case .text:
            let r = a.textRect.insetBy(dx: Annotation.textPadding.width, dy: Annotation.textPadding.height)
            withFlippedNSContext(ctx) {
                (a.text as NSString).draw(with: r, options: [.usesLineFragmentOrigin, .usesFontLeading],
                                          attributes: Annotation.textAttributes(size: a.width, color: a.color))
            }

        case .label:
            drawLabel(a, ctx: ctx)
        }
    }

    private static func drawArrow(_ a: Annotation, ctx: CGContext, color: CGColor) {
        let dx = a.p2.x - a.p1.x, dy = a.p2.y - a.p1.y
        let len = hypot(dx, dy)
        guard len > 0.5 else { return }
        let ux = dx / len, uy = dy / len
        var headLen = max(12, a.width * 3.6)
        if headLen > len * 0.8 { headLen = len * 0.8 }
        let halfW = headLen * 0.48
        let base = CGPoint(x: a.p2.x - ux * headLen, y: a.p2.y - uy * headLen)
        ctx.setStrokeColor(color)
        ctx.setFillColor(color)
        ctx.setLineWidth(a.width)
        ctx.setLineCap(.round)
        ctx.move(to: a.p1)
        ctx.addLine(to: CGPoint(x: base.x + ux * 1, y: base.y + uy * 1))
        ctx.strokePath()
        ctx.setLineJoin(.round)
        ctx.move(to: a.p2)
        ctx.addLine(to: CGPoint(x: base.x - uy * halfW, y: base.y + ux * halfW))
        ctx.addLine(to: CGPoint(x: base.x + uy * halfW, y: base.y - ux * halfW))
        ctx.closePath()
        ctx.fillPath()
    }

    private static func drawLabel(_ a: Annotation, ctx: CGContext) {
        let r = a.labelDotRadius
        let dot = CGRect(x: a.anchor.x - r, y: a.anchor.y - r, width: r * 2, height: r * 2)
        ctx.setFillColor(a.color.cgColor)
        ctx.fillEllipse(in: dot)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(2)
        ctx.strokeEllipse(in: dot.insetBy(dx: 1, dy: 1))
        guard !a.text.isEmpty else { return }
        drawBubble(rect: a.bubbleRect, pointingTo: a.anchor, onLeft: a.bubbleOnLeft, colorIndex: a.colorIndex, ctx: ctx)
        let textRect = a.bubbleRect.insetBy(dx: Annotation.bubblePadding.width, dy: Annotation.bubblePadding.height)
        withFlippedNSContext(ctx) {
            (a.text as NSString).draw(with: textRect, options: [.usesLineFragmentOrigin, .usesFontLeading],
                                      attributes: Annotation.textAttributes(size: a.width, color: Annotation.bubbleTextColor(a.colorIndex)))
        }
    }

    static func drawBubble(rect: CGRect, pointingTo anchor: CGPoint, onLeft: Bool, colorIndex: Int, ctx: CGContext) {
        let color = Palette.color(colorIndex)
        let path = CGMutablePath()
        path.addRoundedRect(in: rect, cornerWidth: 5, cornerHeight: 5)
        let tipX = onLeft ? rect.maxX + 6 : rect.minX - 6
        let edgeX = onLeft ? rect.maxX - 1 : rect.minX + 1
        let midY = min(max(anchor.y, rect.minY + 8), rect.maxY - 8)
        path.move(to: CGPoint(x: edgeX, y: midY - 6))
        path.addLine(to: CGPoint(x: tipX, y: midY))
        path.addLine(to: CGPoint(x: edgeX, y: midY + 6))
        path.closeSubpath()
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: 3, color: NSColor.black.withAlphaComponent(0.25).cgColor)
        ctx.setFillColor(color.cgColor)
        ctx.addPath(path)
        ctx.fillPath()
        ctx.restoreGState()
        if colorIndex == 5 {
            ctx.setStrokeColor(NSColor(hex: 0xDEE0E3).cgColor)
            ctx.setLineWidth(1)
            ctx.addPath(path)
            ctx.strokePath()
        }
    }

    static func drawHandles(_ a: Annotation, in ctx: CGContext) {
        for h in a.handles {
            drawHandle(at: h, ctx: ctx)
        }
    }

    static func drawHandle(at p: CGPoint, ctx: CGContext, radius: CGFloat = 4.5) {
        let r = CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillEllipse(in: r)
        ctx.setStrokeColor(selectionBlue.cgColor)
        ctx.setLineWidth(1.5)
        ctx.strokeEllipse(in: r)
    }

    /// 文字绘制依赖 NSGraphicsContext；离屏渲染时需要临时设置一个。
    static func withFlippedNSContext(_ ctx: CGContext, _ body: () -> Void) {
        if let current = NSGraphicsContext.current, current.cgContext === ctx {
            body()
            return
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        body()
        NSGraphicsContext.restoreGraphicsState()
    }
}
