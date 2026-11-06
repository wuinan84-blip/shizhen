import AppKit
import AVFoundation
import AVKit
import UniformTypeIdentifiers

/// 录完后的剪辑窗口：预览播放、拖动首尾把手、叉 / 下载 / 对勾。
final class TrimWindowController: NSObject, NSWindowDelegate {
    private static var openWindows: [TrimWindowController] = []

    private let url: URL
    private let format: RecordingOptions.Format
    private let asset: AVURLAsset
    private let player: AVPlayer
    private let window: NSWindow
    private let playerView = AVPlayerView()
    private let timeline = TrimTimeline()
    private let playButton = IconButton(symbols: ["play.fill"], tooltip: "播放 / 暂停", height: 30, pointSize: 14)
    private let timeLabel = NSTextField(labelWithString: "")
    private let durationLabel = NSTextField(labelWithString: "")
    private let progressOverlay = ExportProgressView()
    private var timeObserver: Any?
    private var duration: Double = 0
    private var exporting = false
    private var closingConfirmed = false

    static func open(url: URL, format: RecordingOptions.Format) {
        let c = TrimWindowController(url: url, format: format)
        openWindows.append(c)
        NSApp.activate(ignoringOtherApps: true)
        c.window.makeKeyAndOrderFront(nil)
        Task { @MainActor in await c.load() }
    }

    private init(url: URL, format: RecordingOptions.Format) {
        self.url = url
        self.format = format
        asset = AVURLAsset(url: url)
        player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 760, height: 560),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        window.title = format == .gif ? "剪辑录屏（GIF）" : "剪辑录屏（MP4）"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.minSize = CGSize(width: 560, height: 400)
        window.center()
        buildUI()
    }

    private func buildUI() {
        let content = NSView()
        window.contentView = content

        playerView.player = player
        playerView.controlsStyle = .none
        playerView.videoGravity = .resizeAspect
        playerView.translatesAutoresizingMaskIntoConstraints = false
        playerView.wantsLayer = true
        playerView.layer?.backgroundColor = NSColor.black.cgColor

        playButton.action = { [weak self] in self?.togglePlay() }
        timeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        timeLabel.textColor = .secondaryLabelColor
        durationLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        timeline.translatesAutoresizingMaskIntoConstraints = false
        timeline.onRangeChange = { [weak self] handleTime in self?.rangeChanged(seekTo: handleTime) }
        timeline.onSeek = { [weak self] t in self?.seek(t) }

        let cancel = IconButton(symbols: ["xmark"], title: "放弃", tooltip: "放弃这段录屏", height: 30, pointSize: 13)
        cancel.tintColor = UIStyle.red
        cancel.action = { [weak self] in self?.discard() }
        let save = IconButton(symbols: ["arrow.down.to.line"], title: "下载", tooltip: "按剪辑结果导出并保存", height: 30, pointSize: 13)
        save.action = { [weak self] in self?.save() }
        let confirm = IconButton(symbols: ["checkmark"], title: "完成", tooltip: "按剪辑结果导出并复制到剪贴板",
                                 style: .filled(UIStyle.blue), height: 30, pointSize: 13)
        confirm.action = { [weak self] in self?.confirm() }

        let controls = NSStackView(views: [playButton, timeLabel, NSView(), durationLabel])
        controls.orientation = .horizontal
        controls.spacing = 8
        controls.translatesAutoresizingMaskIntoConstraints = false

        let buttons = NSStackView(views: [cancel, NSView(), save, confirm])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        buttons.translatesAutoresizingMaskIntoConstraints = false

        progressOverlay.translatesAutoresizingMaskIntoConstraints = false
        progressOverlay.isHidden = true

        for v in [playerView, controls, timeline, buttons, progressOverlay] as [NSView] { content.addSubview(v) }
        NSLayoutConstraint.activate([
            playerView.topAnchor.constraint(equalTo: content.topAnchor),
            playerView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            controls.topAnchor.constraint(equalTo: playerView.bottomAnchor, constant: 10),
            controls.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            controls.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            timeline.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 8),
            timeline.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            timeline.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            timeline.heightAnchor.constraint(equalToConstant: 52),
            buttons.topAnchor.constraint(equalTo: timeline.bottomAnchor, constant: 14),
            buttons.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            progressOverlay.topAnchor.constraint(equalTo: content.topAnchor),
            progressOverlay.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            progressOverlay.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            progressOverlay.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])
    }

    @MainActor
    private func load() async {
        guard let d = try? await asset.load(.duration) else { return }
        duration = max(CMTimeGetSeconds(d), 0)
        timeline.duration = duration
        timeline.start = 0
        timeline.end = duration
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let size = try? await track.load(.naturalSize), size.width > 0 {
            // 窗口按视频比例调整
            let vf = (window.screen ?? NSScreen.main!).visibleFrame
            let videoW = min(max(size.width / (window.backingScaleFactor), 520), vf.width * 0.7)
            let videoH = min(videoW * size.height / size.width, vf.height * 0.6)
            window.setContentSize(CGSize(width: max(videoW, 560), height: videoH + 150))
            window.center()
        }
        updateLabels()
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] t in
            self?.playbackTick(CMTimeGetSeconds(t))
        }
        await timeline.loadThumbnails(asset: asset)
    }

    // MARK: 播放

    private func togglePlay() {
        if player.rate > 0 {
            player.pause()
        } else {
            let now = CMTimeGetSeconds(player.currentTime())
            if now < timeline.start || now >= timeline.end - 0.05 { seek(timeline.start) }
            player.play()
        }
        updatePlayIcon()
    }

    private func updatePlayIcon() {
        playButton.isSelected = player.rate > 0
    }

    private func seek(_ t: Double) {
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        timeline.playhead = t
        updateLabels()
    }

    private func playbackTick(_ t: Double) {
        timeline.playhead = t
        if player.rate > 0 && t >= timeline.end {
            player.pause()
            seek(timeline.end)
        }
        updatePlayIcon()
        updateLabels()
    }

    private func rangeChanged(seekTo t: Double) {
        player.pause()
        seek(t)
        updatePlayIcon()
    }

    private func updateLabels() {
        let now = timeline.playhead
        timeLabel.stringValue = "\(RecordingSession.format(now)) / \(RecordingSession.format(duration))"
        durationLabel.stringValue = "剪辑后时长 \(RecordingSession.format(max(0, timeline.end - timeline.start).rounded()))"
    }

    // MARK: 结束

    private var range: CMTimeRange {
        let s = CMTime(seconds: timeline.start, preferredTimescale: 600)
        let e = CMTime(seconds: timeline.end, preferredTimescale: 600)
        return CMTimeRange(start: s, end: e)
    }

    private var fileExtension: String { format == .gif ? "gif" : "mp4" }

    private func discard() {
        guard !exporting else { return }
        guard Alerts.confirm("放弃这段录屏？", info: "录制的内容将被删除，不会保存。", ok: "放弃", destructive: true) else { return }
        closingConfirmed = true
        window.close()
    }

    private func save() {
        guard !exporting else { return }
        player.pause()
        let type: UTType = format == .gif ? .gif : .mpeg4Movie
        guard let dst = SavePanel.run(defaultName: Paths.recordingName(ext: fileExtension), type: type) else { return }
        export(to: dst) { [weak self] in
            self?.closingConfirmed = true
            self?.window.close()
        }
    }

    private func confirm() {
        guard !exporting else { return }
        player.pause()
        let dst = Paths.clipboardDir.appendingPathComponent(Paths.recordingName(ext: fileExtension))
        export(to: dst) { [weak self] in
            Clipboard.writeFile(dst)
            self?.closingConfirmed = true
            self?.window.close()
        }
    }

    private func export(to dst: URL, then done: @escaping () -> Void) {
        exporting = true
        progressOverlay.isHidden = false
        progressOverlay.progress = 0
        let src = url, range = self.range, format = self.format
        Task { @MainActor in
            do {
                let report: (Double) -> Void = { [weak self] p in DispatchQueue.main.async { self?.progressOverlay.progress = p } }
                if format == .gif {
                    try await Exporter.exportGIF(from: src, range: range, to: dst, progress: report)
                } else {
                    try await Exporter.exportMP4(from: src, range: range, to: dst, progress: report)
                }
                self.exporting = false
                self.progressOverlay.isHidden = true
                done()
            } catch {
                self.exporting = false
                self.progressOverlay.isHidden = true
                Alerts.info("导出失败", info: error.localizedDescription)
            }
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if exporting { return false }
        if closingConfirmed { return true }
        if Alerts.confirm("放弃这段录屏？", info: "录制的内容将被删除，不会保存。", ok: "放弃", destructive: true) {
            closingConfirmed = true
            return true
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        try? FileManager.default.removeItem(at: url)
        Self.openWindows.removeAll { $0 === self }
    }
}

/// 剪辑时间轴：缩略图 + 首尾把手 + 播放头。
final class TrimTimeline: NSView {
    var duration: Double = 0 { didSet { needsDisplay = true } }
    var start: Double = 0 { didSet { needsDisplay = true } }
    var end: Double = 0 { didSet { needsDisplay = true } }
    var playhead: Double = 0 { didSet { needsDisplay = true } }
    var onRangeChange: ((Double) -> Void)?
    var onSeek: ((Double) -> Void)?

    private var thumbnails: [CGImage] = []
    private enum DragTarget { case start, end, playhead }
    private var dragging: DragTarget?
    private let handleWidth: CGFloat = 12

    override var isFlipped: Bool { true }

    private var track: CGRect { bounds.insetBy(dx: handleWidth, dy: 4) }

    private func x(for t: Double) -> CGFloat {
        guard duration > 0 else { return track.minX }
        return track.minX + CGFloat(t / duration) * track.width
    }

    private func time(at x: CGFloat) -> Double {
        guard track.width > 0 else { return 0 }
        return min(max(Double((x - track.minX) / track.width) * duration, 0), duration)
    }

    func loadThumbnails(asset: AVAsset) async {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 160, height: 100)
        let count = 12
        guard duration > 0 else { return }
        let times = (0..<count).map { CMTime(seconds: duration * (Double($0) + 0.5) / Double(count), preferredTimescale: 600) }
        var images: [CGImage] = []
        for await result in generator.images(for: times) {
            if let img = try? result.image { images.append(img) }
        }
        thumbnails = images
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let t = track
        ctx.saveGState()
        let clip = NSBezierPath(roundedRect: t, xRadius: 4, yRadius: 4)
        clip.addClip()
        NSColor(hex: 0x2B2F36).setFill()
        t.fill()
        if !thumbnails.isEmpty {
            let w = t.width / CGFloat(thumbnails.count)
            for (i, img) in thumbnails.enumerated() {
                let aspect = CGFloat(img.width) / CGFloat(max(img.height, 1))
                let cell = CGRect(x: t.minX + CGFloat(i) * w, y: t.minY, width: w, height: t.height)
                let drawW = max(cell.width, cell.height * aspect)
                let r = CGRect(x: cell.midX - drawW / 2, y: cell.minY, width: drawW, height: cell.height)
                ctx.saveGState()
                ctx.clip(to: cell)
                AnnotationRenderer.drawImage(img, in: r, ctx: ctx)
                ctx.restoreGState()
            }
        }
        // 剪掉的部分变暗
        let sx = x(for: start), ex = x(for: end)
        NSColor.black.withAlphaComponent(0.6).setFill()
        CGRect(x: t.minX, y: t.minY, width: sx - t.minX, height: t.height).fill()
        CGRect(x: ex, y: t.minY, width: t.maxX - ex, height: t.height).fill()
        ctx.restoreGState()

        // 选中范围的边框和把手
        let sel = CGRect(x: sx, y: t.minY, width: ex - sx, height: t.height)
        UIStyle.blue.setStroke()
        let border = NSBezierPath(rect: sel.insetBy(dx: 0, dy: 1))
        border.lineWidth = 2
        border.stroke()
        for (hx, left) in [(sx, true), (ex, false)] {
            let r = CGRect(x: left ? hx - handleWidth : hx, y: t.minY - 2, width: handleWidth, height: t.height + 4)
            UIStyle.blue.setFill()
            NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3).fill()
            NSColor.white.setFill()
            CGRect(x: r.midX - 1, y: r.midY - 7, width: 2, height: 14).fill()
        }
        // 播放头
        let px = x(for: playhead)
        NSColor.white.setFill()
        CGRect(x: px - 1, y: t.minY - 4, width: 2, height: t.height + 8).fill()
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let sx = x(for: start), ex = x(for: end)
        if p.x >= sx - handleWidth - 4 && p.x <= sx + 4 {
            dragging = .start
        } else if p.x >= ex - 4 && p.x <= ex + handleWidth + 4 {
            dragging = .end
        } else {
            dragging = .playhead
            let t = min(max(time(at: p.x), start), end)
            onSeek?(t)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let minGap = min(0.5, duration)
        switch dragging {
        case .start:
            start = min(max(0, time(at: p.x)), end - minGap)
            onRangeChange?(start)
        case .end:
            end = max(min(duration, time(at: p.x)), start + minGap)
            onRangeChange?(end)
        case .playhead:
            onSeek?(min(max(time(at: p.x), start), end))
        case nil:
            break
        }
    }

    override func mouseUp(with event: NSEvent) { dragging = nil }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }
}

/// 导出进度遮罩。
final class ExportProgressView: NSView {
    private let bar = NSProgressIndicator()
    private let label = NSTextField(labelWithString: "正在导出…")

    var progress: Double = 0 {
        didSet {
            bar.doubleValue = progress * 100
            label.stringValue = "正在导出… \(Int(progress * 100))%"
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.85).cgColor
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 100
        bar.style = .bar
        bar.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = NSFont.systemFont(ofSize: 13)
        addSubview(bar)
        addSubview(label)
        NSLayoutConstraint.activate([
            bar.centerXAnchor.constraint(equalTo: centerXAnchor),
            bar.centerYAnchor.constraint(equalTo: centerYAnchor),
            bar.widthAnchor.constraint(equalToConstant: 280),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.bottomAnchor.constraint(equalTo: bar.topAnchor, constant: -10),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { isHidden ? nil : self }
    override func mouseDown(with event: NSEvent) {}
}
