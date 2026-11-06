import AppKit

/// 录制进行中：选区边框、浮动控制条、菜单栏计时、点击高亮、异常自动停止。
final class RecordingSession {
    private(set) static var current: RecordingSession?
    static var isActive: Bool { current != nil }
    /// 菜单栏显示的录制时长；nil 表示不在录制。
    static var onStatusChange: ((String?) -> Void)?

    private let screen: NSScreen
    private let displayID: CGDirectDisplayID
    private let displaySize: CGSize
    private let rect: CGRect
    private let options: RecordingOptions
    private let recorder: Recorder

    private var borderWindow: NSWindow?
    private var controlPanel: NSPanel?
    private var controlBar: RecordingControlBar?
    private var timer: Timer?
    private var clickMonitor: Any?
    private var screenObserver: NSObjectProtocol?
    private var stopping = false

    private var startedAt: CFTimeInterval = 0
    private var pausedTotal: CFTimeInterval = 0
    private var pausedAt: CFTimeInterval?

    static func prepare(screen: NSScreen, rect: CGRect, options: RecordingOptions) async throws -> RecordingSession {
        let s = RecordingSession(screen: screen, rect: rect, options: options)
        try await s.recorder.prepare()
        return s
    }

    private init(screen: NSScreen, rect: CGRect, options: RecordingOptions) {
        self.screen = screen
        self.displayID = ScreenCapturer.displayID(screen)
        self.displaySize = screen.frame.size
        self.rect = rect
        self.options = options
        self.recorder = Recorder(screen: screen, rect: rect, options: options)
    }

    /// 倒计时结束，开始写入。
    func begin() {
        RecordingSession.current = self
        recorder.onStreamError = { [weak self] error in
            self?.stop(reason: "录制被系统中断（\(error.localizedDescription)），已保留录到的部分。")
        }
        recorder.beginWriting()
        startedAt = CACurrentMediaTime()
        showBorder()
        showControlBar()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        tick()
        if options.showCursor {
            clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                self?.recorder.addClick(globalPoint: NSEvent.mouseLocation)
            }
        }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            self?.checkDisplay()
        }
    }

    /// 倒计时被取消：丢弃。
    func discard() {
        recorder.cancel()
    }

    // MARK: 界面

    private var globalRect: CGRect {
        CGRect(x: screen.frame.minX + rect.minX, y: screen.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
    }

    private func showBorder() {
        let w = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.setFrame(screen.frame, display: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.level = .statusBar
        w.isReleasedWhenClosed = false
        w.sharingType = .none
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let v = RecordingBorderView(frame: CGRect(origin: .zero, size: screen.frame.size))
        v.selection = rect
        w.contentView = v
        w.orderFrontRegardless()
        borderWindow = w
    }

    private func showControlBar() {
        let bar = RecordingControlBar()
        bar.onPause = { [weak self] in self?.togglePause() }
        bar.onStop = { [weak self] in self?.stop(reason: nil) }
        let size = bar.fittingBarSize
        let panel = NSPanel(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.sharingType = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let container = NSView(frame: CGRect(origin: .zero, size: CGSize(width: size.width + 24, height: size.height + 24)))
        bar.frame = CGRect(x: 12, y: 12, width: size.width, height: size.height)
        container.addSubview(bar)
        panel.contentView = container
        panel.setContentSize(container.frame.size)

        // 控制条放在选区下方；不够放上方；都不够放选区内底部
        let g = globalRect
        let gap: CGFloat = 8
        var barY = g.minY - gap - size.height
        if barY < screen.frame.minY + 4 {
            barY = g.maxY + gap
            if barY + size.height > screen.visibleFrame.maxY - 4 { barY = g.minY + gap }
        }
        var barX = g.maxX - size.width
        barX = min(max(barX, screen.frame.minX + 4), screen.frame.maxX - size.width - 4)
        panel.setFrameOrigin(CGPoint(x: barX - 12, y: barY - 12))
        panel.orderFrontRegardless()
        controlPanel = panel
        controlBar = bar
    }

    private var elapsed: CFTimeInterval {
        let now = CACurrentMediaTime()
        let pausing = pausedAt.map { now - $0 } ?? 0
        return max(0, now - startedAt - pausedTotal - pausing)
    }

    static func format(_ t: CFTimeInterval) -> String {
        let s = Int(t)
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60) }
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    private func tick() {
        let text = Self.format(elapsed)
        controlBar?.timeText = text
        RecordingSession.onStatusChange?(text)
        if Paths.freeDiskSpace() < 300 * 1024 * 1024 {
            stop(reason: "磁盘空间不足，已自动停止录制并保留录到的部分。")
        }
    }

    private func togglePause() {
        if let p = pausedAt {
            pausedTotal += CACurrentMediaTime() - p
            pausedAt = nil
            recorder.resume()
            controlBar?.isPaused = false
        } else {
            pausedAt = CACurrentMediaTime()
            recorder.pause()
            controlBar?.isPaused = true
        }
        tick()
    }

    private func checkDisplay() {
        let stillThere = NSScreen.screens.first { ScreenCapturer.displayID($0) == displayID }
        if stillThere == nil || stillThere?.frame.size != displaySize {
            stop(reason: "显示器已断开或分辨率发生变化，已自动停止录制并保留录到的部分。")
        }
    }

    // MARK: 停止

    func stop(reason: String?) {
        guard !stopping else { return }
        stopping = true
        timer?.invalidate()
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        borderWindow?.orderOut(nil)
        controlPanel?.orderOut(nil)
        HoverTip.shared.hide()
        borderWindow = nil
        controlPanel = nil
        let format = options.format
        Task { @MainActor in
            let url = await self.recorder.stop()
            RecordingSession.current = nil
            RecordingSession.onStatusChange?(nil)
            guard let url else {
                Alerts.info("没有录到内容", info: reason ?? "录制时间太短，没有生成视频。")
                return
            }
            TrimWindowController.open(url: url, format: format)
            if let reason { Alerts.info("录制已停止", info: reason) }
        }
    }
}

/// 录制中的选区边框（不会被录进去）。
final class RecordingBorderView: NSView {
    var selection: CGRect = .zero
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setStrokeColor(UIStyle.red.cgColor)
        ctx.setLineWidth(2)
        ctx.setLineDash(phase: 0, lengths: [6, 4])
        ctx.stroke(selection.insetBy(dx: -2, dy: -2))
    }
}

/// 浮动控制条：红点 + 时长、暂停 / 继续、停止。
final class RecordingControlBar: BarView {
    var onPause: (() -> Void)?
    var onStop: (() -> Void)?

    private let dot = NSView()
    private let label = NSTextField(labelWithString: "00:00")
    private let pauseButton = IconButton(symbols: ["pause.fill"], title: "暂停", height: 28, pointSize: 12)
    private let stopButton = IconButton(symbols: ["stop.fill"], title: "停止", style: .filled(UIStyle.red), height: 28, pointSize: 12)

    var timeText = "00:00" { didSet { label.stringValue = timeText } }

    var isPaused = false {
        didSet {
            pauseButton.title = isPaused ? "继续" : "暂停"
            dot.layer?.backgroundColor = (isPaused ? UIStyle.disabled : UIStyle.red).cgColor
        }
    }

    override init() {
        super.init()
        dot.wantsLayer = true
        dot.layer?.backgroundColor = UIStyle.red.cgColor
        dot.layer?.cornerRadius = 5
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: 10).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 10).isActive = true
        label.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        label.textColor = UIStyle.text
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(greaterThanOrEqualToConstant: 62).isActive = true
        pauseButton.action = { [weak self] in self?.onPause?() }
        stopButton.action = { [weak self] in self?.onStop?() }
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 12, bottom: 4, right: 6)
        setViews([dot, label, SeparatorView(), pauseButton, stopButton])
    }

    required init?(coder: NSCoder) { fatalError() }
}
