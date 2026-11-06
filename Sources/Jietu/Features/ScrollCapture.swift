import AppKit
import ScreenCaptureKit
import SwiftUI

enum ScrollCaptureResult {
    case cancelled
    case finished(CGImage, CGFloat)
}

final class ScrollPanelModel: ObservableObject {
    @Published var preview: NSImage?
    @Published var status = "请在选区内向下滚动，或点「自动滚动」"
    @Published var warning: String?
    @Published var autoScrolling = false
    @Published var stitchedHeight = 0

    var onAuto: (() -> Void)?
    var onFinish: (() -> Void)?
    var onCancel: (() -> Void)?
}

struct ScrollPanelView: View {
    @ObservedObject var model: ScrollPanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("滚动截图").font(.system(size: 13, weight: .semibold))
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor))
                if let img = model.preview {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fit).padding(4)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(height: 300)
            Text(model.stitchedHeight > 0 ? "已拼接 \(model.stitchedHeight) 像素" : " ")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Text(model.warning ?? model.status)
                .font(.system(size: 12))
                .foregroundStyle(model.warning == nil ? Color.secondary : Color.red)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(model.autoScrolling ? "停止滚动" : "自动滚动") { model.onAuto?() }
                Spacer()
                Button("取消") { model.onCancel?() }
                Button("完成") { model.onFinish?() }.keyboardShortcut(.defaultAction)
            }
            Text("提示：选区尽量只框住会滚动的内容，避开动画和视频。点「自动滚动」前，先把鼠标在要滚动的内容上停一下，自动滚动会在那里滚。")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 250)
    }
}

final class ScrollCapturePanel: NSPanel {
    var onEscape: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

/// 滚动截图：实时采集选区画面并拼接，滚动操作直接传给下面的应用。
final class ScrollCaptureController: NSObject, SCStreamOutput, SCStreamDelegate {
    static var current: ScrollCaptureController?

    private let screen: NSScreen
    private let rect: CGRect
    private let scale: CGFloat
    private let completion: (ScrollCaptureResult) -> Void
    private let stitcher = Stitcher()
    private let queue = DispatchQueue(label: "jietu.scroll-capture")
    private let model = ScrollPanelModel()
    private var panel: ScrollCapturePanel!
    private var stream: SCStream?
    private var finished = false

    /// 以下两个只在 queue 上访问。
    private lazy var autoScroller = AutoScroller(stitcher: stitcher, viewHeight: rect.height, scale: scale)
    private var autoActive = false
    private var autoGeneration = 0
    private var autoCenter = CGPoint.zero
    private var debugDumps = 0
    private var limitReached = false
    private var lastPreviewTime: CFTimeInterval = 0
    private var previewPending = false
    private var pointerMonitor: Any?
    /// 鼠标最后一次停在选区里的位置（全局坐标，左上角为原点），自动滚动就在这里滚。
    private var lastPointer: CGPoint?

    static func start(screen: NSScreen, rect: CGRect, anchor: CGRect, completion: @escaping (ScrollCaptureResult) -> Void) {
        let c = ScrollCaptureController(screen: screen, rect: rect, completion: completion)
        current = c
        c.showPanel(near: anchor)
        c.installPointerMonitor()
        Task { @MainActor in
            do {
                try await c.startStream()
            } catch {
                c.model.warning = "无法开始采集：\(error.localizedDescription)"
            }
        }
    }

    private init(screen: NSScreen, rect: CGRect, completion: @escaping (ScrollCaptureResult) -> Void) {
        self.screen = screen
        self.rect = rect
        self.scale = screen.backingScaleFactor
        self.completion = completion
        super.init()
        model.onAuto = { [weak self] in self?.toggleAuto() }
        model.onFinish = { [weak self] in self?.finish() }
        model.onCancel = { [weak self] in self?.cancel() }
    }

    private func showPanel(near anchor: CGRect) {
        let p = ScrollCapturePanel(contentRect: CGRect(x: 0, y: 0, width: 250, height: 480),
                                   styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isMovableByWindowBackground = true
        p.level = .capturePanel
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.onEscape = { [weak self] in self?.cancel() }
        let host = NSHostingView(rootView: ScrollPanelView(model: model))
        p.contentView = host
        p.setContentSize(host.fittingSize)
        let size = p.frame.size
        let vf = screen.visibleFrame
        var x = anchor.maxX + 12
        if x + size.width > vf.maxX { x = anchor.minX - 12 - size.width }
        if x < vf.minX { x = anchor.maxX - size.width - 12 }
        x = min(max(x, vf.minX + 4), vf.maxX - size.width - 4)
        let y = min(max(anchor.maxY - size.height, vf.minY + 4), vf.maxY - size.height - 4)
        p.setFrameOrigin(CGPoint(x: x, y: y))
        panel = p
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
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
        let height = stitcher.height
        DispatchQueue.main.async { [weak self] in self?.handle(result, height: height) }
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
            self?.model.warning = "采集已停止：\(error.localizedDescription)"
        }
    }

    private func handle(_ result: Stitcher.AddResult, height: Int) {
        guard !finished else { return }
        model.stitchedHeight = height
        switch result {
        case .noMatch:
            // 自动滚动时滚过头会自己往回找，不提示
            if !model.autoScrolling {
                model.warning = "这一段没接上：请往回滚一点，再继续往下滚。如果一直接不上，请缩小选区，只框住会滚动的内容。"
            }
        case .grew:
            model.warning = nil
            if !model.autoScrolling { model.status = "继续滚动，或点「完成」" }
            schedulePreview()
        case .limitReached:
            limitReached = true
            model.warning = "已达到长图高度上限（\(Stitcher.maxHeight) 像素），请点「完成」。"
            stopAuto()
            schedulePreview()
        case .unchanged:
            if !limitReached { model.warning = nil }
        }
    }

    private func schedulePreview() {
        guard !previewPending else { return }
        previewPending = true
        let delay = max(0, 0.25 - (CACurrentMediaTime() - lastPreviewTime))
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            let img = self.stitcher.makeImage(maxRowsFromBottom: max(self.stitcher.width * 2, 1))
            DispatchQueue.main.async {
                self.previewPending = false
                self.lastPreviewTime = CACurrentMediaTime()
                if let img { self.model.preview = NSImage(cgImage: img, size: NSSize(width: img.width, height: img.height)) }
            }
        }
    }

    // MARK: 自动滚动

    private func toggleAuto() {
        if model.autoScrolling { stopAuto(); return }
        guard Permission.accessibility.isGranted else {
            PermissionAlert.show(.accessibility, message: "「自动滚动」需要模拟滚轮操作其他应用，需要「辅助功能」权限。手动滚动不受影响。",
                                 level: .capturePanel)
            return
        }
        guard !limitReached, stream != nil else { return }
        model.autoScrolling = true
        model.warning = nil
        model.status = "正在自动滚动…"
        let global = globalRect
        let target = lastPointer ?? CGPoint(x: global.midX, y: global.midY)
        CGWarpMouseCursorPosition(target)
        queue.async { [weak self] in
            guard let self, !self.finished else { return }
            self.autoCenter = target
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
                let height = self.stitcher.height
                DispatchQueue.main.async { self.handle(result, height: height) }
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

    /// points 为正时向下滚动（内容向上移动）。
    private func postScroll(_ points: CGFloat) {
        let delta = Int32((-points).rounded())
        guard delta != 0,
              let ev = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0) else { return }
        ev.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        ev.location = autoCenter
        ev.post(tap: .cghidEventTap)
    }

    private func autoStopped(_ reason: AutoScroller.StopReason) {
        guard model.autoScrolling else { return }
        model.autoScrolling = false
        switch reason {
        case .reachedBottom:
            model.status = "已滚动到底部，请点「完成」"
        case .noResponse:
            model.warning = "页面没有响应自动滚动。请把鼠标移到要滚动的内容上再试，或改用手动滚动。"
        case .failed:
            model.warning = "自动滚动时拼接失败，可能是选区里有动画或悬浮元素。请缩小选区后重试，或改用手动滚动。"
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
        if model.autoScrolling {
            model.autoScrolling = false
            model.status = "继续滚动，或点「完成」"
        }
    }

    // MARK: 结束

    private func teardown() {
        finished = true
        stopAuto()
        if let pointerMonitor { NSEvent.removeMonitor(pointerMonitor) }
        pointerMonitor = nil
        if let stream { Task { try? await stream.stopCapture() } }
        stream = nil
        panel.orderOut(nil)
        panel.close()
        ScrollCaptureController.current = nil
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        queue.async { [weak self] in
            guard let self else { return }
            let image = self.stitcher.makeImage()
            DispatchQueue.main.async {
                self.teardown()
                if let image {
                    self.completion(.finished(image, self.scale))
                } else {
                    self.completion(.cancelled)
                }
            }
        }
    }

    private func cancel() {
        guard !finished else { return }
        teardown()
        completion(.cancelled)
    }
}
