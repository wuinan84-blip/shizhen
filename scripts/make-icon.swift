// 生成 Resources/AppIcon.icns：swift scripts/make-icon.swift
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent(".build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    let inset = s * 0.1
    let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let path = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    NSGradient(starting: NSColor(red: 0.30, green: 0.55, blue: 1.0, alpha: 1),
               ending: NSColor(red: 0.13, green: 0.32, blue: 0.90, alpha: 1))!.draw(in: path, angle: -90)

    // 取景框四角
    NSColor.white.withAlphaComponent(0.9).setStroke()
    let f = rect.insetBy(dx: rect.width * 0.17, dy: rect.width * 0.17)
    let len = f.width * 0.22
    let corner = NSBezierPath()
    corner.lineWidth = s * 0.035
    corner.lineCapStyle = .round
    for (x, y, dx, dy) in [(f.minX, f.minY, 1.0, 1.0), (f.maxX, f.minY, -1.0, 1.0), (f.minX, f.maxY, 1.0, -1.0), (f.maxX, f.maxY, -1.0, -1.0)] {
        corner.move(to: CGPoint(x: x + dx * len, y: y))
        corner.line(to: CGPoint(x: x, y: y))
        corner.line(to: CGPoint(x: x, y: y + dy * len))
    }
    corner.stroke()

    // 剪刀
    let config = NSImage.SymbolConfiguration(pointSize: s * 0.3, weight: .semibold)
        .applying(.init(paletteColors: [.white]))
    if let sym = NSImage(systemSymbolName: "scissors", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let sz = sym.size
        sym.draw(in: CGRect(x: (s - sz.width) / 2, y: (s - sz.height) / 2, width: sz.width, height: sz.height))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try! task.run()
task.waitUntilExit()
print(task.terminationStatus == 0 ? "已生成 Resources/AppIcon.icns" : "iconutil 失败")
