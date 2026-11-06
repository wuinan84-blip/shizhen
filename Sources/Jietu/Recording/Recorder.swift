import AppKit
import AVFoundation
import ScreenCaptureKit

/// 录制选区：ScreenCaptureKit 采集，AVAssetWriter 写入临时 .mov。
/// 系统声音和麦克风先分两条音轨写入，导出时再混成一条。
final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate {
    let outputURL: URL
    let options: RecordingOptions
    let pixelWidth: Int
    let pixelHeight: Int
    let fps: Int32

    var onStreamError: ((Error) -> Void)?

    private let screen: NSScreen
    private let rect: CGRect
    private var stream: SCStream?
    private let videoQueue = DispatchQueue(label: "jietu.rec.video")
    private let audioQueue = DispatchQueue(label: "jietu.rec.audio")
    private let lock = NSLock()

    // 以下状态由 lock 保护
    private var writing = false
    private var paused = false
    private var stopped = false
    private var pauseOffset = CMTime.zero
    private var pauseStartedAt: CMTime?
    private var resumeAt: CMTime?
    private var clicks: [(point: CGPoint, time: Double)] = []
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var systemInput: AVAssetWriterInput?
    private var micInput: AVAssetWriterInput?
    private var systemFormat: CMFormatDescription?
    private var micFormat: CMFormatDescription?
    private var sessionStart: CMTime?

    // 以下只在 videoQueue 上访问
    private var writerCreated = false
    private var lastVideoTime = CMTime.invalid
    private var framesWritten = 0

    init(screen: NSScreen, rect: CGRect, options: RecordingOptions) {
        self.screen = screen
        self.rect = rect
        self.options = options
        self.fps = options.format == .mp4 ? 30 : 15
        let scale = screen.backingScaleFactor
        var w = rect.width * scale, h = rect.height * scale
        // H.264 硬件编码最大 4096
        let limit: CGFloat = 4096
        if max(w, h) > limit {
            let f = limit / max(w, h)
            w *= f; h *= f
        }
        pixelWidth = max(2, Int(w) / 2 * 2)
        pixelHeight = max(2, Int(h) / 2 * 2)
        outputURL = Paths.recordingsDir.appendingPathComponent("rec-\(UUID().uuidString).mov")
        super.init()
    }

    var hasAudio: Bool { options.format == .mp4 && (options.microphone || options.systemAudio) }

    // MARK: 采集

    func prepare() async throws {
        let content = try await ScreenCapturer.content()
        let display = try ScreenCapturer.display(for: screen, in: content)
        let filter = ScreenCapturer.filterExcludingSelf(display: display, content: content)
        let config = SCStreamConfiguration()
        config.sourceRect = rect
        config.width = pixelWidth
        config.height = pixelHeight
        config.scalesToFit = false
        config.minimumFrameInterval = CMTime(value: 1, timescale: fps)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.showsCursor = options.showCursor
        config.queueDepth = 8
        let mp4 = options.format == .mp4
        config.capturesAudio = mp4 && options.systemAudio
        config.sampleRate = 48000
        config.channelCount = 2
        config.excludesCurrentProcessAudio = true
        if mp4 && options.microphone {
            config.captureMicrophone = true
            config.microphoneCaptureDeviceID = AVCaptureDevice.default(for: .audio)?.uniqueID
        }

        let s = SCStream(filter: filter, configuration: config, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        if config.capturesAudio { try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue) }
        if config.captureMicrophone { try s.addStreamOutput(self, type: .microphone, sampleHandlerQueue: audioQueue) }
        try await s.startCapture()
        stream = s
    }

    /// 倒计时结束：从下一帧开始写入。
    func beginWriting() {
        lock.withLock { writing = true }
    }

    func pause() {
        lock.withLock {
            guard writing, !paused else { return }
            paused = true
            pauseStartedAt = CMClockGetTime(CMClockGetHostTimeClock())
        }
    }

    func resume() {
        lock.withLock {
            guard paused, let started = pauseStartedAt else { return }
            let now = CMClockGetTime(CMClockGetHostTimeClock())
            pauseOffset = CMTimeAdd(pauseOffset, CMTimeSubtract(now, started))
            resumeAt = now
            paused = false
            pauseStartedAt = nil
        }
    }

    /// 记录一次点击（全局坐标，Cocoa 左下角原点）。
    func addClick(globalPoint p: CGPoint) {
        guard options.showCursor else { return }
        let localX = p.x - screen.frame.minX - rect.minX
        let localY = (screen.frame.maxY - p.y) - rect.minY
        guard localX >= -20, localY >= -20, localX <= rect.width + 20, localY <= rect.height + 20 else { return }
        let px = CGPoint(x: localX * CGFloat(pixelWidth) / rect.width, y: localY * CGFloat(pixelHeight) / rect.height)
        let t = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
        lock.withLock {
            clicks.append((px, t))
            clicks.removeAll { t - $0.time > 1 }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in self?.onStreamError?(error) }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sb.isValid else { return }
        switch type {
        case .screen: handleVideo(sb)
        case .audio: handleAudio(sb, mic: false)
        case .microphone: handleAudio(sb, mic: true)
        @unknown default: break
        }
    }

    /// 返回调整后的时间；nil 表示这帧不写。
    private func adjustedTime(_ pts: CMTime) -> CMTime? {
        lock.withLock {
            guard writing, !paused, !stopped else { return nil }
            if let r = resumeAt, CMTimeCompare(pts, r) < 0 { return nil }
            return CMTimeSubtract(pts, pauseOffset)
        }
    }

    private func handleVideo(_ sb: CMSampleBuffer) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        guard let time = adjustedTime(pts) else { return }
        if !writerCreated {
            writerCreated = true
            createWriter()
        }
        let parts: (AVAssetWriter, AVAssetWriterInput, AVAssetWriterInputPixelBufferAdaptor)? = lock.withLock {
            guard let writer, let videoInput, let adaptor, writer.status == .writing else { return nil }
            if sessionStart == nil {
                writer.startSession(atSourceTime: time)
                sessionStart = time
            }
            return (writer, videoInput, adaptor)
        }
        guard let (_, videoInput, adaptor) = parts else { return }
        if lastVideoTime.isValid && CMTimeCompare(time, lastVideoTime) <= 0 { return }
        drawClicks(on: pb, frameTime: CMTimeGetSeconds(pts))
        if videoInput.isReadyForMoreMediaData, adaptor.append(pb, withPresentationTime: time) {
            lastVideoTime = time
            framesWritten += 1
        }
    }

    private func handleAudio(_ sb: CMSampleBuffer, mic: Bool) {
        guard let format = CMSampleBufferGetFormatDescription(sb) else { return }
        lock.withLock {
            if mic { if micFormat == nil { micFormat = format } } else if systemFormat == nil { systemFormat = format }
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        guard let time = adjustedTime(pts) else { return }
        // 写入器在第一帧画面到来时创建；在那之前的声音丢弃
        let input: AVAssetWriterInput? = lock.withLock {
            guard let writer, let start = sessionStart, writer.status == .writing, CMTimeCompare(time, start) >= 0 else { return nil }
            return mic ? micInput : systemInput
        }
        guard let input, input.isReadyForMoreMediaData, let retimed = retime(sb, to: time) else { return }
        input.append(retimed)
    }

    private func retime(_ sb: CMSampleBuffer, to time: CMTime) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(duration: CMSampleBufferGetDuration(sb), presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sb, sampleTimingEntryCount: 1,
                                              sampleTimingArray: &timing, sampleBufferOut: &out)
        return out
    }

    private func createWriter() {
        do {
            let w = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
            w.movieFragmentInterval = CMTime(seconds: 5, preferredTimescale: 600)
            let bitrate = max(2_000_000, Int(Double(pixelWidth * pixelHeight) * Double(fps) * 0.12))
            let settings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: pixelWidth,
                AVVideoHeightKey: pixelHeight,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: bitrate,
                    AVVideoExpectedSourceFrameRateKey: fps,
                    AVVideoMaxKeyFrameIntervalKey: fps,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                ] as [String: Any],
            ]
            let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            vIn.expectsMediaDataInRealTime = true
            w.add(vIn)
            let ad = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vIn, sourcePixelBufferAttributes: nil)

            let formats: (CMFormatDescription?, CMFormatDescription?) = lock.withLock { (systemFormat, micFormat) }
            var sysIn: AVAssetWriterInput?, micIn: AVAssetWriterInput?
            if options.format == .mp4 && options.systemAudio {
                let input = makeAudioInput(hint: formats.0, defaultChannels: 2)
                if w.canAdd(input) { w.add(input); sysIn = input }
            }
            if options.format == .mp4 && options.microphone {
                let input = makeAudioInput(hint: formats.1, defaultChannels: 1)
                if w.canAdd(input) { w.add(input); micIn = input }
            }
            guard w.startWriting() else {
                NSLog("录制写入启动失败：\(String(describing: w.error))")
                return
            }
            lock.withLock {
                writer = w
                videoInput = vIn
                adaptor = ad
                systemInput = sysIn
                micInput = micIn
            }
        } catch {
            NSLog("创建录制文件失败：\(error)")
        }
    }

    private func makeAudioInput(hint: CMFormatDescription?, defaultChannels: Int) -> AVAssetWriterInput {
        var channels = defaultChannels
        var rate = 48000.0
        if let hint, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(hint)?.pointee {
            channels = min(2, max(1, Int(asbd.mChannelsPerFrame)))
            rate = asbd.mSampleRate
        }
        if rate > 48000 || rate < 8000 { rate = 48000 }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: channels == 1 ? 96000 : 160000,
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings, sourceFormatHint: hint)
        input.expectsMediaDataInRealTime = true
        return input
    }

    // MARK: 点击高亮

    private func drawClicks(on pb: CVPixelBuffer, frameTime: Double) {
        let active: [(CGPoint, Double)] = lock.withLock {
            clicks.filter { frameTime - $0.time >= 0 && frameTime - $0.time <= 0.3 }.map { ($0.point, $0.time) }
        }
        guard !active.isEmpty else { return }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        guard let ctx = CGContext(data: base, width: w, height: h, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return }
        let pxPerPt = CGFloat(pixelWidth) / rect.width
        for (p, t) in active {
            let progress = CGFloat((frameTime - t) / 0.3)
            let radius = (14 + 10 * progress) * pxPerPt
            let alpha = 0.5 * (1 - progress)
            let center = CGPoint(x: p.x, y: CGFloat(h) - p.y)
            let r = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            ctx.setFillColor(NSColor(hex: 0xFFC60A, alpha: alpha * 0.8).cgColor)
            ctx.fillEllipse(in: r)
            ctx.setStrokeColor(NSColor(hex: 0xF5A300, alpha: alpha).cgColor)
            ctx.setLineWidth(2 * pxPerPt)
            ctx.strokeEllipse(in: r.insetBy(dx: pxPerPt, dy: pxPerPt))
        }
    }

    // MARK: 结束

    /// 停止并写完文件。没有录到任何画面时返回 nil。
    func stop() async -> URL? {
        lock.withLock { stopped = true; writing = false }
        if let stream { try? await stream.stopCapture() }
        stream = nil
        // 等两个队列上正在处理的样本写完
        let (frames, lastTime): (Int, CMTime) = videoQueue.sync { (framesWritten, lastVideoTime) }
        audioQueue.sync {}
        let parts = lock.withLock { (writer, [videoInput, systemInput, micInput].compactMap { $0 }) }
        guard let writer = parts.0 else { return nil }
        guard frames > 0 else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: outputURL)
            return nil
        }
        parts.1.forEach { $0.markAsFinished() }
        if lastTime.isValid { writer.endSession(atSourceTime: CMTimeAdd(lastTime, CMTime(value: 1, timescale: fps))) }
        await writer.finishWriting()
        if writer.status != .completed {
            NSLog("录制文件写入失败：\(String(describing: writer.error))")
            return FileManager.default.fileExists(atPath: outputURL.path) ? outputURL : nil
        }
        return outputURL
    }

    func cancel() {
        lock.withLock { stopped = true; writing = false }
        let s = stream
        stream = nil
        Task {
            if let s { try? await s.stopCapture() }
            self.videoQueue.sync {}
            let w: AVAssetWriter? = self.lock.withLock { self.writer }
            if w?.status == .writing { w?.cancelWriting() }
            try? FileManager.default.removeItem(at: self.outputURL)
        }
    }
}
