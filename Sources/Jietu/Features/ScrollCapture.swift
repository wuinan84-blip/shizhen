import AppKit
import ScreenCaptureKit

enum ScrollCaptureResult {
    /// 回到选区阶段。
    case cancelled
    /// 已复制或已保存，结束本次截图。
    case done
    /// 打开长图编辑窗口。
    case edit(CGImage, CGFloat)
}

/// 滚动截图：实时采集选区画面并拼接，滚动操作直接传给下面的应用。
final class ScrollCaptureController: NSObject, SCStreamOutput, SCStreamDelegate {
    static var current: ScrollCaptureController?

    private enum Output { case copy, save, edit }

    private let screen: NSScreen
    private let rect: CGRect
    private let scale: CGFloat
    private let completion: (ScrollCaptureResult) -> Void
    private let stitcher = Stitcher()
    private let queue = DispatchQueue(label: "jietu.scroll-capture")
    private let hud: ScrollCaptureHUD
    private var stream: SCStream?
    private var finished = false
    private var busy = false
    private var autoScrolling = false
    private var warningShown = false

    /// 以下几个只在 queue 上访问。
    private lazy var autoScroller = AutoScroller(stitcher: stitcher, viewHeight: rect.height, scale: scale)
    private var autoActive = false
    private var autoGeneration = 0
    private var autoCenter = CGPoint.zero
    private var autoTarget: BackgroundScroll.Target?
    private var debugDumps = 0
    private var limitReached = false
    private var lastPreviewTime: CFTimeInterval = 0
    private var previewPending = false
    private var pointerMonitor: Any?
    /// 鼠标最后一次停在选区里的位置（全局坐标，左上角为原点），自动滚动就在这里滚。
    private var lastPointer: CGPoint?

    static func start(screen: NSScreen, rect: CGRect, anchor: CGRect, completion: @escaping (ScrollCaptureResult) -> Void) {
        let c = ScrollCaptureController(screen: screen, rect: rect, anchor: anchor, completion: completion)
        current = c
        c.hud.show()
        c.hud.toast("请缓慢向上或向下滚动页面，或点击「自动滚动」，开始截图", duration: 4)
        c.installPointerMonitor()
        Task { @MainActor in
            do {
                try await c.startStream()
            } catch {
                c.hud.toast("无法开始采集：\(error.localizedDescription)", warning: true, duration: nil)
            }
        }
    }

    private init(screen: NSScreen, rect: CGRect, anchor: CGRect, completion: @escaping (ScrollCaptureResult) -> Void) {
        self.screen = screen
        self.rect = rect
        self.scale = screen.backingScaleFactor
        self.completion = completion
        self.hud = ScrollCaptureHUD(selection: anchor, screen: screen)
        super.init()
        hud.onAuto = { [weak self] in self?.toggleAuto() }
        hud.onFinish = { [weak self] in self?.output(.copy) }
        hud.onSave = { [weak self] in self?.output(.save) }
        hud.onEdit = { [weak self] in self?.output(.edit) }
        hud.onCancel = { [weak self] in self?.cancel() }
        hud.onKey = { [weak self] e in self?.handleKey(e) ?? false }
    }

    private func handleKey(_ e: NSEvent) -> Bool {
        let prefs = Prefs.shared
        if prefs.shortcut(.cancel).matches(e) { cancel(); return true }
        if prefs.shortcut(.confirm).matches(e) { output(.copy); return true }
        if prefs.shortcut(.save).matches(e) { output(.save); return true }
        return false
    }

    private func startStream() async throws {
        let content = try await ScreenCapturer.content()
        let display = try ScreenCapturer.display(for: screen, in: content)
        let filter = ScreenCapturer.filterExcludingSelf(display: display, content: content)
        let config = SCStreamConfiguration()
        config.sourceRect = rect
        config.width = Int((rect.width * scale).rounded())
        config.height = Int((rect.height * scale).rounded())
        config.minimumFrameInterval = CMTime(value: 1, timescale: 20)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.showsCursor = false
        config.queueDepth = 4
        let s = SCStream(filter: filter, configuration: config, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await s.startCapture()
        if finished { try? await s.stopCapture(); return }
        stream = s
    }

    // MARK: 采集

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, !finished,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        if autoActive {
            autoScroller.frameArrived(pb, at: CACurrentMediaTime())
            return
        }
        let result = stitcher.add(pb)
        if result == .noMatch { dumpFailureIfNeeded() }
        DispatchQueue.main.async { [weak self] in self?.handle(result) }
    }

    /// 拼接失败时把画面存到缓存目录，方便排查（每次滚动截图最多 3 份，24 小时后清理）。在 queue 上执行。
    private func dumpFailureIfNeeded() {
        guard debugDumps < 3, let f = stitcher.takeFailure() else { return }
        debugDumps += 1
        let dir = Paths.scrollDebugDir.appendingPathComponent("\(Paths.timestamp()) 第\(debugDumps)次", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let d = ImageFile.pngData(f.frame, scale: scale) { try? d.write(to: dir.appendingPathComponent("当前帧.png")) }
        if let r = f.recent, let d = ImageFile.pngData(r, scale: scale) { try? d.write(to: dir.appendingPathComponent("已拼接的末尾.png")) }
        try? f.info.write(to: dir.appendingPathComponent("信息.txt"), atomically: true, encoding: .utf8)
    }

    private var globalRect: CGRect {
        let b = CGDisplayBounds(ScreenCapturer.displayID(screen))
        return CGRect(x: b.minX + rect.minX, y: b.minY + rect.minY, width: rect.width, height: rect.height)
    }

    private func installPointerMonitor() {
        let global = globalRect.insetBy(dx: 4, dy: 4)
        pointerMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .scrollWheel]) { [weak self] _ in
            guard let self, let p = CGEvent(source: nil)?.location, global.contains(p) else { return }
            self.lastPointer = p
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.hud.toast("采集已停止：\(error.localizedDescription)", warning: true, duration: nil)
        }
    }

    private func handle(_ result: Stitcher.AddResult) {
        guard !finished else { return }
        switch result {
        case .noMatch:
            // 自动滚动时滚过头会自己往回找，不提示
            if !autoScrolling {
                warningShown = true
                hud.toast("这一段没接上：请往回滚一点，再继续往下滚。如果一直接不上，请缩小选区，只框住会滚动的内容。",
                          warning: true, duration: nil)
            }
        case .grew:
            clearWarning()
            schedulePreview()
        case .limitReached:
            limitReached = true
            warningShown = true
            hud.toast("已达到长图高度上限（\(Stitcher.maxHeight) 像素），请点「完成」", warning: true, duration: nil)
            stopAuto()
            schedulePreview()
        case .unchanged:
            if !limitReached { clearWarning() }
        }
    }

    private func clearWarning() {
        guard warningShown else { return }
        warningShown = false
        hud.hideToast()
    }

    private func schedulePreview() {
        guard !previewPending else { return }
        previewPending = true
        let delay = max(0, 0.4 - (CACurrentMediaTime() - lastPreviewTime))
        let size = hud.previewPixelSize
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            let img = self.stitcher.makeThumbnail(maxWidth: size.width, maxHeight: size.height)
            DispatchQueue.main.async {
                self.previewPending = false
                self.lastPreviewTime = CACurrentMediaTime()
                if let img, !self.finished { self.hud.setPreview(img) }
            }
        }
    }

    // MARK: 自动滚动

    private func toggleAuto() {
        guard !finished, !busy else { return }
        if autoScrolling { stopAuto(); return }
        guard Permission.accessibility.isGranted else {
            PermissionAlert.show(.accessibility, message: "「自动滚动」需要模拟滚轮操作其他应用，需要「辅助功能」权限。手动滚动不受影响。",
                                 level: .capturePanel)
            return
        }
        guard !limitReached, stream != nil else { return }
        autoScrolling = true
        hud.autoScrolling = true
        clearWarning()
        let global = globalRect
        let target = lastPointer ?? CGPoint(x: global.midX, y: global.midY)
        let window = BackgroundScroll.target(at: target)
        queue.async { [weak self] in
            guard let self, !self.finished else { return }
            self.autoCenter = target
            self.autoTarget = window
            self.autoActive = true
            self.autoGeneration += 1
            self.apply(self.autoScroller.start(at: CACurrentMediaTime()))
            self.scheduleAutoTick(self.autoGeneration)
        }
    }

    /// 在 queue 上执行。
    private func scheduleAutoTick(_ generation: Int) {
        queue.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, self.autoActive, generation == self.autoGeneration, !self.finished else { return }
            let (result, action) = self.autoScroller.tick(at: CACurrentMediaTime())
            if let result {
                if result == .noMatch { self.dumpFailureIfNeeded() }
                DispatchQueue.main.async { self.handle(result) }
            }
            self.apply(action)
            if self.autoActive { self.scheduleAutoTick(generation) }
        }
    }

    /// 在 queue 上执行。
    private func apply(_ action: AutoScroller.Action) {
        switch action {
        case .none:
            break
        case .scroll(let points):
            postScroll(points)
        case .stop(let reason):
            autoActive = false
            DispatchQueue.main.async { [weak self] in self?.autoStopped(reason) }
        }
    }

    /// points 为正时向下滚动（内容向上移动）。在 queue 上执行。
    private func postScroll(_ points: CGFloat) {
        let pixels = Int32(points.rounded())
        guard pixels != 0 else { return }
        let point = autoCenter
        guard let target = autoTarget else {
            // 找不到目标窗口时只在鼠标所在处滚，不去拉动鼠标
            CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -pixels, wheel2: 0, wheel3: 0)?
                .post(tap: .cghidEventTap)
            return
        }
        DispatchQueue.main.async {
            BackgroundScroll.hover(target, at: point)
            self.queue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self, self.autoActive, !self.finished else { return }
                BackgroundScroll.scroll(target, at: point, pixels: pixels)
            }
        }
    }

    private func autoStopped(_ reason: AutoScroller.StopReason) {
        guard autoScrolling else { return }
        autoScrolling = false
        hud.autoScrolling = false
        switch reason {
        case .reachedBottom:
            hud.toast("已滚动到底部，可以点「完成」了")
        case .noResponse:
            hud.toast("页面没有响应自动滚动。请把鼠标移到要滚动的内容上再试，或改用手动滚动。", warning: true, duration: 5)
        case .failed:
            hud.toast("自动滚动时没接上，可能是选区里有动画或悬浮元素。请缩小选区后重试，或改用手动滚动。", warning: true, duration: 5)
        case .limitReached:
            break
        }
    }

    private func stopAuto() {
        queue.async { [weak self] in
            guard let self else { return }
            self.autoActive = false
            self.autoScroller.stop()
        }
        autoScrolling = false
        hud.autoScrolling = false
    }

    // MARK: 结束

    private func teardown() {
        finished = true
        stopAuto()
        if let pointerMonitor { NSEvent.removeMonitor(pointerMonitor) }
        pointerMonitor = nil
        if let stream { Task { try? await stream.stopCapture() } }
        stream = nil
        hud.close()
        ScrollCaptureController.current = nil
    }

    private func output(_ kind: Output) {
        guard !finished, !busy else { return }
        busy = true
        stopAuto()
        queue.async { [weak self] in
            guard let self else { return }
            let image = self.stitcher.makeImage()
            DispatchQueue.main.async { self.deliver(image, kind) }
        }
    }

    private func deliver(_ image: CGImage?, _ kind: Output) {
        busy = false
        guard !finished else { return }
        guard let image else {
            hud.toast("还没有截到画面，请先滚动页面", warning: true)
            return
        }
        switch kind {
        case .copy:
            Clipboard.writeImage(image, scale: scale)
            teardown()
            completion(.done)
        case .edit:
            teardown()
            completion(.edit(image, scale))
        case .save:
            guard let url = SavePanel.run(defaultName: Paths.screenshotName(), type: .png, level: .capturePanel) else {
                hud.makeKey()
                return
            }
            do {
                guard let data = ImageFile.pngData(image, scale: scale) else { throw CocoaError(.fileWriteUnknown) }
                try data.write(to: url)
                teardown()
                completion(.done)
            } catch {
                Alerts.info("保存失败", info: error.localizedDescription, level: .capturePanel)
                hud.makeKey()
            }
        }
    }

    private func cancel() {
        guard !finished, !busy else { return }
        teardown()
        completion(.cancelled)
    }
}
