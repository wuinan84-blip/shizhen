import AppKit
import ScreenCaptureKit

extension NSWindow.Level {
    /// 截图遮罩所在层级：盖住菜单栏和程序坞。
    static let captureOverlay = NSWindow.Level.screenSaver
    /// 截图过程中弹出的面板、对话框，要在遮罩之上。
    static let capturePanel = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
}

enum CaptureError: LocalizedError {
    case displayNotFound
    var errorDescription: String? { "没有找到当前显示器" }
}

enum ScreenCapturer {
    static func displayID(_ screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
    }

    static func screenUnderMouse() -> NSScreen {
        let p = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    static func content() async throws -> SCShareableContent {
        try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    }

    static func display(for screen: NSScreen, in content: SCShareableContent) throws -> SCDisplay {
        let id = displayID(screen)
        guard let d = content.displays.first(where: { $0.displayID == id }) else { throw CaptureError.displayNotFound }
        return d
    }

    /// 排除本应用所有窗口（遮罩、工具栏、控制条等）的过滤器。
    static func filterExcludingSelf(display: SCDisplay, content: SCShareableContent) -> SCContentFilter {
        let pid = ProcessInfo.processInfo.processIdentifier
        let me = content.applications.filter { $0.processID == pid }
        if me.isEmpty {
            return SCContentFilter(display: display, excludingWindows: content.windows.filter { $0.owningApplication?.processID == pid })
        }
        return SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])
    }

    /// 冻结整块显示器的画面（实际像素）。
    static func captureScreen(_ screen: NSScreen) async throws -> CGImage {
        let content = try await content()
        let display = try display(for: screen, in: content)
        let filter = filterExcludingSelf(display: display, content: content)
        let config = SCStreamConfiguration()
        let scale = screen.backingScaleFactor
        config.width = Int((screen.frame.width * scale).rounded())
        config.height = Int((screen.frame.height * scale).rounded())
        config.showsCursor = false
        config.captureResolution = .best
        config.ignoreShadowsDisplay = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    /// 屏幕上的窗口（从前到后），坐标转换为该显示器左上角原点的 pt。
    static func windowRects(on screen: NSScreen) -> [CGRect] {
        let displayBounds = CGDisplayBounds(displayID(screen))
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        let myPID = ProcessInfo.processInfo.processIdentifier
        let local = CGRect(origin: .zero, size: displayBounds.size)
        var rects: [CGRect] = []
        for w in info {
            guard (w[kCGWindowLayer as String] as? Int) == 0 else { continue }
            if (w[kCGWindowOwnerPID as String] as? Int32) == myPID { continue }
            if let alpha = w[kCGWindowAlpha as String] as? Double, alpha < 0.05 { continue }
            guard let dict = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: dict), r.width >= 40, r.height >= 40 else { continue }
            let clipped = r.offsetBy(dx: -displayBounds.minX, dy: -displayBounds.minY).intersection(local)
            if clipped.isNull || clipped.width < 20 || clipped.height < 20 { continue }
            rects.append(clipped)
        }
        return rects
    }
}

final class OverlayWindow: NSWindow {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        level = .captureOverlay
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
