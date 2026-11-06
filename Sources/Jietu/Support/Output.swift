import AppKit
import UniformTypeIdentifiers

enum Clipboard {
    /// 图片数据放进剪贴板（PNG + TIFF），不生成文件。
    static func writeImage(_ image: CGImage, scale: CGFloat) {
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.declareTypes([.png, .tiff], owner: nil)
        if let png = rep.representation(using: .png, properties: [:]) { pb.setData(png, forType: .png) }
        if let tiff = rep.tiffRepresentation { pb.setData(tiff, forType: .tiff) }
    }

    /// 文件放进剪贴板（视频、GIF 只能以文件形式粘贴）。
    static func writeFile(_ url: URL) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([url as NSURL])
    }
}

enum ImageFile {
    static func pngData(_ image: CGImage, scale: CGFloat) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        return rep.representation(using: .png, properties: [:])
    }
}

enum SavePanel {
    /// 弹出「存储为」窗口，记住上次选择的文件夹。取消时返回 nil。
    static func run(defaultName: String, type: UTType, level: NSWindow.Level? = nil) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = defaultName
        panel.allowedContentTypes = [type]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.directoryURL = Prefs.shared.lastSaveDirectory
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        if let level { panel.level = level }
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        Prefs.shared.lastSaveDirectory = url.deletingLastPathComponent()
        return url
    }
}

enum Alerts {
    static func confirm(_ title: String, info: String = "", ok: String, cancel: String = "取消",
                        level: NSWindow.Level? = nil, destructive: Bool = false) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = info
        let okButton = alert.addButton(withTitle: ok)
        okButton.hasDestructiveAction = destructive
        alert.addButton(withTitle: cancel)
        NSApp.activate(ignoringOtherApps: true)
        if let level { alert.window.level = level }
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func info(_ title: String, info: String = "", level: NSWindow.Level? = nil) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = info
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        if let level { alert.window.level = level }
        alert.runModal()
    }
}
