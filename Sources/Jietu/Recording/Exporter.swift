import AVFoundation
import ImageIO
import UniformTypeIdentifiers

enum ExportError: LocalizedError {
    case noVideo
    case failed(String)
    var errorDescription: String? {
        switch self {
        case .noVideo: return "录制文件里没有画面。"
        case .failed(let s): return s
        }
    }
}

/// 按剪辑范围导出 MP4（H.264 + AAC，多路声音混成一条音轨）或 GIF。
enum Exporter {
    static func exportMP4(from src: URL, range: CMTimeRange, to dst: URL, progress: @escaping (Double) -> Void) async throws {
        try? FileManager.default.removeItem(at: dst)
        let asset = AVURLAsset(url: src)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else { throw ExportError.noVideo }
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let size = try await videoTrack.load(.naturalSize)
        let transform = try await videoTrack.load(.preferredTransform)

        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = range
        let videoOut = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        videoOut.alwaysCopiesSampleData = false
        reader.add(videoOut)
        var audioOut: AVAssetReaderAudioMixOutput?
        if !audioTracks.isEmpty {
            let out = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
                AVLinearPCMIsBigEndianKey: false,
            ])
            out.alwaysCopiesSampleData = false
            if reader.canAdd(out) { reader.add(out); audioOut = out }
        }

        let writer = try AVAssetWriter(outputURL: dst, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        let w = Int(size.width), h = Int(size.height)
        let bitrate = max(2_000_000, Int(Double(w * h) * 30 * 0.12))
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate, AVVideoExpectedSourceFrameRateKey: 30,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ] as [String: Any],
        ])
        videoIn.transform = transform
        videoIn.expectsMediaDataInRealTime = false
        writer.add(videoIn)
        var audioIn: AVAssetWriterInput?
        if audioOut != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 160000,
            ])
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            audioIn = input
        }

        guard reader.startReading() else { throw ExportError.failed("读取录制文件失败：\(reader.error?.localizedDescription ?? "")") }
        guard writer.startWriting() else { throw ExportError.failed("创建导出文件失败：\(writer.error?.localizedDescription ?? "")") }
        writer.startSession(atSourceTime: range.start)

        let duration = max(CMTimeGetSeconds(range.duration), 0.001)
        let start = CMTimeGetSeconds(range.start)
        async let videoDone: Void = pump(videoOut, into: videoIn, label: "video") { t in
            progress(min(1, max(0, (CMTimeGetSeconds(t) - start) / duration)))
        }
        if let audioOut, let audioIn {
            async let audioDone: Void = pump(audioOut, into: audioIn, label: "audio") { _ in }
            _ = await (videoDone, audioDone)
        } else {
            await videoDone
        }

        if reader.status == .failed {
            writer.cancelWriting()
            throw ExportError.failed("读取录制文件失败：\(reader.error?.localizedDescription ?? "")")
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw ExportError.failed("导出失败：\(writer.error?.localizedDescription ?? "")")
        }
        progress(1)
    }

    private static func pump(_ output: AVAssetReaderOutput, into input: AVAssetWriterInput, label: String,
                             onSample: @escaping (CMTime) -> Void) async {
        let queue = DispatchQueue(label: "jietu.export.\(label)")
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            var finished = false
            input.requestMediaDataWhenReady(on: queue) {
                guard !finished else { return }
                while input.isReadyForMoreMediaData {
                    guard let sb = output.copyNextSampleBuffer() else {
                        finished = true
                        input.markAsFinished()
                        cont.resume()
                        return
                    }
                    onSample(CMSampleBufferGetPresentationTimeStamp(sb))
                    if !input.append(sb) {
                        finished = true
                        input.markAsFinished()
                        cont.resume()
                        return
                    }
                }
            }
        }
    }

    /// GIF：15 帧 / 秒，循环播放，宽度超过 1280 时等比缩小。
    static func exportGIF(from src: URL, range: CMTimeRange, to dst: URL, progress: @escaping (Double) -> Void) async throws {
        try? FileManager.default.removeItem(at: dst)
        let asset = AVURLAsset(url: src)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw ExportError.noVideo }
        let size = try await track.load(.naturalSize)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let tolerance = CMTime(value: 1, timescale: 30)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        if size.width > 1280 {
            generator.maximumSize = CGSize(width: 1280, height: ceil(size.height * 1280 / size.width))
        }

        let fps = 15.0
        let duration = CMTimeGetSeconds(range.duration)
        let count = max(1, Int((duration * fps).rounded(.down)))
        let times = (0..<count).map { CMTimeAdd(range.start, CMTime(seconds: Double($0) / fps, preferredTimescale: 600)) }

        guard let dest = CGImageDestinationCreateWithURL(dst as CFURL, UTType.gif.identifier as CFString, count, nil) else {
            throw ExportError.failed("无法创建 GIF 文件。")
        }
        CGImageDestinationSetProperties(dest, [
            kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFLoopCount as String: 0],
        ] as CFDictionary)
        let frameProps = [
            kCGImagePropertyGIFDictionary as String: [
                kCGImagePropertyGIFDelayTime as String: 1.0 / fps,
                kCGImagePropertyGIFUnclampedDelayTime as String: 1.0 / fps,
            ],
        ] as CFDictionary

        var done = 0
        var lastImage: CGImage?
        for await result in generator.images(for: times) {
            if let image = try? result.image { lastImage = image }
            if let img = lastImage { CGImageDestinationAddImage(dest, img, frameProps) }
            done += 1
            progress(Double(done) / Double(count) * 0.95)
        }
        guard lastImage != nil else { throw ExportError.failed("无法读取录制画面。") }
        guard CGImageDestinationFinalize(dest) else { throw ExportError.failed("GIF 写入失败。") }
        progress(1)
    }
}
