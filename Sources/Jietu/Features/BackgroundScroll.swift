import AppKit

/// 不移动真实鼠标，直接给某个窗口发滚轮。
///
/// 经过系统事件流的滚轮只会发给鼠标所在的窗口：事件的位置就是鼠标位置，指定别的位置会把真实鼠标拉过去。
/// 所以绕过系统事件流直接发给目标进程。但应用（AppKit、Chromium/Electron）只把滚轮交给它记录的
/// 「鼠标所在窗口」，只发滚轮会被丢掉；要先发一个带窗口信息的鼠标移动，让它认为鼠标在这个窗口的这个位置上。
/// 做法参考 axcli（github.com/andelf/axcli）的 scroll_wheel_bg，已在 Chrome（前台/后台）和 Cursor 上实测。
enum BackgroundScroll {
    struct Target {
        let pid: pid_t
        let windowID: CGWindowID
        /// 全局坐标，左上角为原点。
        let bounds: CGRect
    }

    /// 屏幕上这个点（全局坐标，左上角为原点）最上层的普通窗口，不含自己的。
    static func target(at p: CGPoint) -> Target? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        let me = ProcessInfo.processInfo.processIdentifier
        for info in list {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let alpha = info[kCGWindowAlpha as String] as? Double, alpha > 0,
                  let b = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: b), bounds.contains(p) else { continue }
            return Target(pid: pid, windowID: id, bounds: bounds)
        }
        return nil
    }

    /// 第一步：让目标应用认为鼠标在 point 上。须在主线程调用（要用 NSEvent 构造事件）。
    /// 之后约 0.1 秒再调用 scroll，应用要先处理完这个鼠标移动。
    static func hover(_ t: Target, at point: CGPoint) {
        let id = Int64(t.windowID)
        guard let ev = NSEvent.mouseEvent(with: .mouseMoved, location: NSPoint(x: point.x, y: point.y),
                                          modifierFlags: isActive(t) ? [] : .command,
                                          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: Int(t.windowID),
                                          context: nil, eventNumber: 0, clickCount: 0, pressure: 1)?.cgEvent else { return }
        ev.location = point
        ev.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: id)
        ev.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: id)
        ev.setIntegerValueField(.mouseEventSubtype, value: 3)
        ev.setIntegerValueField(.mouseEventButtonNumber, value: 0)
        setWindowLocation?(ev, local(t, point))
        ev.postToPid(t.pid)
    }

    /// 第二步：滚动。pixels 为正时向下滚（内容向上移动）。
    static func scroll(_ t: Target, at point: CGPoint, pixels: Int32) {
        let id = Int64(t.windowID)
        guard let ev = CGEvent(scrollWheelEvent2Source: CGEventSource(stateID: .hidSystemState), units: .pixel,
                               wheelCount: 1, wheel1: -pixels, wheel2: 0, wheel3: 0) else { return }
        ev.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        ev.location = point
        ev.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: id)
        ev.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: id)
        if let windowNumberField = CGEventField(rawValue: 51) { ev.setIntegerValueField(windowNumberField, value: id) }
        setWindowLocation?(ev, local(t, point))
        // 目标应用不在前台时（滚动截图时前台是拾帧的面板），带上 Command 标记它才会处理
        if !isActive(t) { ev.flags = .maskCommand }
        ev.postToPid(t.pid)
    }

    private static func isActive(_ t: Target) -> Bool {
        NSRunningApplication(processIdentifier: t.pid)?.isActive ?? false
    }

    private static func local(_ t: Target, _ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - t.bounds.minX, y: point.y - t.bounds.minY)
    }

    /// 系统私有函数：写入事件在窗口内的坐标。找不到时（系统改动）仍然发送，只是部分应用可能不响应。
    private typealias SetWindowLocation = @convention(c) (CGEvent, CGPoint) -> Void
    private static let setWindowLocation: SetWindowLocation? = {
        guard let p = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGEventSetWindowLocation") else { return nil }
        return unsafeBitCast(p, to: SetWindowLocation.self)
    }()
}
