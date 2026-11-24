import CoreGraphics
import CoreVideo
import Foundation

/// 滚动截图拼接：找出相邻两帧之间画面滚动了多少像素，把新露出的部分接到长图上。
///
/// 每一行压缩成若干个列区间的平均亮度，按「平均差异最小」找滚动距离，允许少量像素差异
/// （小数像素滚动时文字抗锯齿不同、悬停效果等）。不随滚动变化的列（侧边栏）不参与比较；
/// 第一次滚动时，选区顶部和底部不动的部分（吸顶标题栏、底部输入框等）识别为固定区，
/// 长图里只在最上面 / 最下面各出现一次。
final class Stitcher {
    static let maxHeight = 30000

    enum AddResult { case unchanged, grew, noMatch, limitReached }

    private static let binCount = 64
    /// 列区间平均亮度差异在这个范围内视为没变（0–255）。
    private static let staticTolerance: Float = 1.5

    private struct Frame {
        let rows: Int
        /// rows × binCount，按行存储。
        let feat: [Float]
    }

    private enum Match {
        case same
        case moved(Int, header: Int, footer: Int)
        case none(String)
    }

    private(set) var width = 0
    private var frameHeight = 0
    private var bandsFixed = false
    private var headerRows = 0
    private var footerRows = 0
    private var headerStrip: CGImage?
    private var footerStrip: CGImage?
    /// 滚动区域的图片条带，从上到下。
    private var strips: [CGImage] = []
    /// 关键帧：新画面都和它比较，滚动超过一定距离才换成新的一帧。
    /// 小数像素滚动时每次估计都有不到 1 像素的误差，逐帧比较会越积越多。
    private var key: Frame?
    private var keyTop = 0
    /// 上一帧到这一帧滚动的距离，用来预计下一帧。
    private var lastStep = 0
    /// 最近一次接上的那一帧，其滚动区域顶部在长图滚动内容中的位置（像素，向下为正）。
    private(set) var viewTop = 0
    private(set) var contentTop = 0
    private(set) var contentBottom = 0
    private(set) var reachedLimit = false
    private var failure: (frame: CGImage, info: String)?
    private var failureReported = false
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    var height: Int { contentBottom - contentTop + headerRows + footerRows }

    /// hint：预计这一帧相对上一帧滚动的距离（像素），画面有重复花纹、几个位置都对得上时优先选最接近的。
    func add(_ pb: CVPixelBuffer, hint: Int? = nil) -> AddResult {
        if reachedLimit { return .limitReached }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return .unchanged }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        let frame = makeFrame(base: base, width: w, height: h, bytesPerRow: bpr)

        guard let prev = key, w == width, h == frameHeight else {
            // 第一帧
            width = w
            frameHeight = h
            strips = [copyRows(base: base, bytesPerRow: bpr, from: 0, to: h)].compactMap { $0 }
            key = frame
            keyTop = 0
            lastStep = 0
            bandsFixed = false
            headerRows = 0
            footerRows = 0
            headerStrip = nil
            footerStrip = nil
            viewTop = 0
            contentTop = 0
            contentBottom = h
            return .grew
        }

        // 还没有滚动过（也没有外部预计）时不知道这一帧会滚多少
        let step = hint ?? (lastStep != 0 ? lastStep : nil)
        switch match(prev: prev, cur: frame, hint: step.map { (viewTop - keyTop) + $0 }) {
        case .none(let info):
            if failure == nil && !failureReported, let img = copyRows(base: base, bytesPerRow: bpr, from: 0, to: h) {
                failure = (img, info)
            }
            return .noMatch

        case .same:
            // 和关键帧位置相同（可能有局部变化），用新的一帧当关键帧
            key = frame
            lastStep = keyTop - viewTop
            viewTop = keyTop
            failureReported = false
            return .unchanged

        case .moved(let dy, let header, let footer):
            failureReported = false
            if !bandsFixed { fixBands(header: header, footer: footer) }
            let region = frameHeight - headerRows - footerRows
            let newTop = keyTop + dy
            let newBottom = newTop + region
            var grew = false
            if newBottom > contentBottom {
                var rows = newBottom - contentBottom
                if height + rows > Stitcher.maxHeight {
                    rows = max(0, Stitcher.maxHeight - height)
                    reachedLimit = true
                }
                let end = headerRows + region
                let start = end - (newBottom - contentBottom)
                if rows > 0, let strip = copyRows(base: base, bytesPerRow: bpr, from: start, to: start + rows) {
                    strips.append(strip)
                    contentBottom += rows
                    grew = true
                }
            } else if newTop < contentTop {
                var rows = contentTop - newTop
                if height + rows > Stitcher.maxHeight {
                    rows = max(0, Stitcher.maxHeight - height)
                    reachedLimit = true
                }
                let end = headerRows + (contentTop - newTop)
                if rows > 0, let strip = copyRows(base: base, bytesPerRow: bpr, from: end - rows, to: end) {
                    strips.insert(strip, at: 0)
                    contentTop -= rows
                    grew = true
                }
            }
            // 底部固定区取最新一帧的：识别成固定区的也可能是暂时没变的内容，滚到底时要用最后一屏的
            if footerRows > 0, newBottom >= contentBottom, let f = copyRows(base: base, bytesPerRow: bpr, from: frameHeight - footerRows, to: frameHeight) {
                footerStrip = f
            }
            lastStep = newTop - viewTop
            viewTop = newTop
            if abs(newTop - keyTop) > region * 3 / 10 {
                key = frame
                keyTop = newTop
            }
            if reachedLimit { return .limitReached }
            return grew ? .grew : .unchanged
        }
    }

    /// 取出最近一次拼接失败时的画面和诊断信息（每段连续失败只给一次）。
    func takeFailure() -> (frame: CGImage, recent: CGImage?, info: String)? {
        guard let failure else { return nil }
        self.failure = nil
        failureReported = true
        let info = failure.info + String(format: "\n帧 %dx%d，固定区 顶部 %d / 底部 %d 像素，已拼接 %d 像素，上一帧滚动 %d 像素，距关键帧 %d 像素",
                                         width, frameHeight, headerRows, footerRows, height, lastStep, viewTop - keyTop)
        return (failure.frame, makeImage(maxRowsFromBottom: frameHeight * 2), info)
    }

    private func fixBands(header: Int, footer: Int) {
        bandsFixed = true
        guard header > 0 || footer > 0, strips.count == 1, let first = strips.first else { return }
        let region = frameHeight - header - footer
        headerStrip = header > 0 ? first.cropping(to: CGRect(x: 0, y: 0, width: width, height: header)) : nil
        footerStrip = footer > 0 ? first.cropping(to: CGRect(x: 0, y: header + region, width: width, height: footer)) : nil
        guard let body = first.cropping(to: CGRect(x: 0, y: header, width: width, height: region)) else { return }
        strips = [body]
        headerRows = header
        footerRows = footer
        keyTop = 0
        viewTop = 0
        contentTop = 0
        contentBottom = region
    }

    /// 整帧的粗略指纹，用来判断画面是否还在变化（隔行隔列采样）。
    static func signature(_ pb: CVPixelBuffer) -> UInt64 {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return 0 }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        var hash: UInt64 = 0xcbf29ce484222325
        var y = 0
        while y < h {
            let row = base.advanced(by: y * bpr).assumingMemoryBound(to: UInt32.self)
            var x = 0
            while x < w {
                hash = (hash ^ UInt64(row[x] & 0x00FFFFFF)) &* 0x100000001b3
                x += 2
            }
            y += 2
        }
        return hash
    }

    // MARK: 行特征

    private func makeFrame(base: UnsafeMutableRawPointer, width w: Int, height h: Int, bytesPerRow bpr: Int) -> Frame {
        let k = Self.binCount
        // 右侧留出滚动条区域，不参与比较
        let x0 = min(w / 20, 8)
        let x1 = max(x0 + k, w - max(w / 25, 28))
        let span = x1 - x0
        var bounds = [Int](repeating: 0, count: k + 1)
        for i in 0...k { bounds[i] = min(w, x0 + span * i / k) }
        var feat = [Float](repeating: 0, count: h * k)
        feat.withUnsafeMutableBufferPointer { out in
            for y in 0..<h {
                let row = base.advanced(by: y * bpr).assumingMemoryBound(to: UInt32.self)
                for b in 0..<k {
                    let s = bounds[b], e = bounds[b + 1]
                    guard e > s else { continue }
                    var sum: UInt32 = 0
                    var x = s
                    while x < e {
                        let px = row[x]
                        sum &+= ((px >> 16) & 0xFF) &* 77 &+ ((px >> 8) & 0xFF) &* 150 &+ (px & 0xFF) &* 29
                        x += 1
                    }
                    out[y * k + b] = Float(sum) / Float((e - s) * 256)
                }
            }
        }
        return Frame(rows: h, feat: feat)
    }

    // MARK: 找滚动距离

    /// 当前帧滚动区域第 r 行 = 上一帧滚动区域第 r + dy 行。hint 为预计的 dy，不知道时为空。
    private func match(prev: Frame, cur: Frame, hint: Int?) -> Match {
        let h = cur.rows, k = Self.binCount
        let tol = Self.staticTolerance
        return prev.feat.withUnsafeBufferPointer { P -> Match in
            cur.feat.withUnsafeBufferPointer { C -> Match in
                // 1. 哪些列区间变了（不变的是侧边栏、空白边距等）
                var dynamic: [Int] = []
                for b in 0..<k {
                    var y = 0
                    while y < h {
                        if abs(C[y * k + b] - P[y * k + b]) > tol { dynamic.append(b); break }
                        y += 1
                    }
                }
                if dynamic.isEmpty { return .same }

                // 2. 哪些行变了；变化很少（光标闪烁、小动画）视为没滚动
                var changed = [Bool](repeating: false, count: h)
                var changedCount = 0
                for y in 0..<h {
                    for b in dynamic where abs(C[y * k + b] - P[y * k + b]) > tol {
                        changed[y] = true
                        changedCount += 1
                        break
                    }
                }
                if changedCount < max(3, h / 50) { return .same }

                // 3. 顶部、底部不动的固定区
                var header = headerRows, footer = footerRows
                if !bandsFixed {
                    header = changed.firstIndex(of: true) ?? 0
                    footer = h - 1 - (changed.lastIndex(of: true) ?? (h - 1))
                    let cap = h * 35 / 100
                    header = min(header, cap)
                    footer = min(footer, cap)
                }
                let region = h - header - footer
                if region < h * 3 / 10 { return .same }

                // 4. 每行的概要（平均亮度、行内对比度），先粗找候选
                let dn = Float(dynamic.count)
                func profile(_ F: UnsafeBufferPointer<Float>) -> ([Float], [Float]) {
                    var mean = [Float](repeating: 0, count: region)
                    var contrast = [Float](repeating: 0, count: region)
                    for r in 0..<region {
                        let o = (header + r) * k
                        var s: Float = 0
                        for b in dynamic { s += F[o + b] }
                        let m = s / dn
                        var c: Float = 0
                        for b in dynamic { c += abs(F[o + b] - m) }
                        mean[r] = m
                        contrast[r] = c / dn
                    }
                    return (mean, contrast)
                }
                let (pm, pc) = profile(P)
                let (cm, cc) = profile(C)
                let minOverlap = max(12, region * 15 / 100)
                let maxShift = region - minOverlap
                let step = region > 700 ? 2 : 1
                var coarse = [Float](repeating: .infinity, count: 2 * maxShift + 1)
                for dy in -maxShift...maxShift {
                    let r0 = max(0, -dy), r1 = min(region, region - dy)
                    var s: Float = 0
                    var n = 0
                    var r = r0
                    while r < r1 {
                        s += abs(cm[r] - pm[r + dy]) + abs(cc[r] - pc[r + dy])
                        n += 1
                        r += step
                    }
                    if n > 0 { coarse[dy + maxShift] = s / Float(n) }
                }
                var minima: [(Int, Float)] = []
                for i in 0..<coarse.count {
                    let v = coarse[i]
                    if (i == 0 || v <= coarse[i - 1]) && (i == coarse.count - 1 || v <= coarse[i + 1]) {
                        minima.append((i - maxShift, v))
                    }
                }
                minima.sort { $0.1 < $1.1 }
                var candidates = Set(minima.prefix(8).map { $0.0 })
                for extra in [0, hint ?? 0] where abs(extra) <= maxShift { candidates.insert(extra) }

                // 5. 在候选附近用全部列区间精确比较
                var fineCache: [Int: Float] = [:]
                func fine(_ dy: Int) -> Float {
                    if let v = fineCache[dy] { return v }
                    let r0 = max(0, -dy), r1 = min(region, region - dy)
                    var s: Float = 0
                    var n = 0
                    var r = r0
                    while r < r1 {
                        let oc = (header + r) * k, op = (header + r + dy) * k
                        for b in dynamic { s += abs(C[oc + b] - P[op + b]) }
                        n += 1
                        r += step
                    }
                    let v = n > 0 ? s / (Float(n) * dn) : .infinity
                    fineCache[dy] = v
                    return v
                }
                // 每个候选取附近 ±2 像素里最好的位置；相距 3 像素以内的视为同一个位置
                var peaks: [(Int, Float)] = []
                for c in candidates {
                    var local: (Int, Float)?
                    for d in (c - 2)...(c + 2) where abs(d) <= maxShift {
                        let v = fine(d)
                        if local == nil || v < local!.1 { local = (d, v) }
                    }
                    if let local { peaks.append(local) }
                }
                peaks.sort { $0.1 < $1.1 }
                var distinct: [(Int, Float)] = []
                for p in peaks where !distinct.contains(where: { abs($0.0 - p.0) <= 3 }) { distinct.append(p) }
                guard !distinct.isEmpty else { return .none("没有候选位置") }

                // 6. 画面本身的纹理：错开 2 像素时的平均差异，用来判断「对得上」的标准
                var texture: Float = 0
                var tn = 0
                var r = 0
                while r + 2 < region {
                    let o1 = (header + r) * k, o2 = (header + r + 2) * k
                    for b in dynamic { texture += abs(C[o1 + b] - C[o2 + b]) }
                    tn += 1
                    r += step
                }
                texture = tn > 0 ? texture / (Float(tn) * dn) : 0
                if texture < 0.8 { return .same }
                let threshold = min(max(texture * 0.4, 1.0), 10)

                // 7. 去掉差异最大的 1/4 行再比一次：不随滚动的水印、悬浮提示、光标等只影响少数行，
                //    对得上的位置会降到接近 0，错开的位置仍然明显
                var rowDiff = [Float](repeating: 0, count: region / step + 1)
                func robust(_ dy: Int) -> Float {
                    var n = 0
                    var r = max(0, -dy)
                    while r < min(region, region - dy) {
                        let oc = (header + r) * k, op = (header + r + dy) * k
                        var s: Float = 0
                        for b in dynamic { s += abs(C[oc + b] - P[op + b]) }
                        rowDiff[n] = s
                        n += 1
                        r += step
                    }
                    guard n > 0 else { return .infinity }
                    rowDiff[0..<n].sort()
                    let keep = max(1, n * 3 / 4)
                    var s: Float = 0
                    for i in 0..<keep { s += rowDiff[i] }
                    return s / (Float(keep) * dn)
                }
                // 真的滚动了 dy，变了的那些行错开 dy 后应该对得上，好过按「没动」比（实测真实滚动不超过 0.71 倍）；
                // 悬浮提示这类新出现的局部内容，错开多少都对不上，不能算作滚动
                func changedRowsDiff(_ dy: Int) -> Float {
                    var s: Float = 0
                    var n = 0
                    for r in max(0, -dy)..<min(region, region - dy) where changed[header + r] {
                        let oc = (header + r) * k, op = (header + r + dy) * k
                        for b in dynamic { s += abs(C[oc + b] - P[op + b]) }
                        n += 1
                    }
                    return n > 0 ? s / (Float(n) * dn) : .infinity
                }
                let unmoved = changedRowsDiff(0)
                var peaksToScore = distinct.filter { $0.0 == 0 || changedRowsDiff($0.0) < unmoved * 0.85 }
                if !peaksToScore.contains(where: { $0.0 == 0 }) { peaksToScore.append((0, fine(0))) }
                // 两个差异一起排：只看平均会被局部遮挡带偏，只看去掉 1/4 后的，大片空白的页面里错开的位置也接近 0
                typealias Scored = (dy: Int, mean: Float, robust: Float)
                func score(_ s: Scored) -> Float { s.mean + 2 * s.robust }
                let scored: [Scored] = peaksToScore.map { (dy: $0.0, mean: $0.1, robust: robust($0.0)) }
                    .sorted { score($0) < score($1) }
                let best = scored[0]
                let robustThreshold = min(max(texture * 0.15, 0.5), 4)
                guard best.mean <= threshold || best.robust <= robustThreshold else {
                    return .none(String(format: "最佳位置 %d 像素的差异 %.2f 超过阈值 %.2f，去掉最差 1/4 行后 %.2f 超过 %.2f（纹理 %.2f，变化的列区间 %d/%d，变化的行 %d/%d）",
                                        best.dy, best.mean, threshold, best.robust, robustThreshold, texture, dynamic.count, k, changedCount, h))
                }

                // 8. 别的位置也差不多一样好（重复的表格行等）：只有离预计滚动距离足够近才采用，
                //    否则宁可当作没接上，也不要接错位置漏掉内容
                let rivals = scored.dropFirst().filter {
                    $0.mean < max(best.mean * 2, best.mean + 0.5) && $0.robust < max(best.robust * 2, best.robust + 0.5)
                }
                if rivals.isEmpty { return best.dy == 0 ? .same : .moved(best.dy, header: header, footer: footer) }
                let options = [best] + rivals
                let list = options.map { "\($0.dy)" }.joined(separator: "、")
                guard let hint, let near = options.min(by: { abs($0.dy - hint) < abs($1.dy - hint) }) else {
                    return .none("几个位置都差不多对得上（\(list) 像素），不知道滚动了多少")
                }
                let spacing = options.filter { $0.dy != near.dy }.map { abs($0.dy - near.dy) }.min() ?? Int.max
                guard abs(near.dy - hint) * 3 <= spacing else {
                    return .none("几个位置都差不多对得上（\(list) 像素），离预计的 \(hint) 像素都不够近")
                }
                return near.dy == 0 ? .same : .moved(near.dy, header: header, footer: footer)
            }
        }
    }

    // MARK: 图片

    private func copyRows(base: UnsafeMutableRawPointer, bytesPerRow bpr: Int, from r0: Int, to r1: Int) -> CGImage? {
        let rows = r1 - r0
        guard rows > 0, width > 0 else { return nil }
        let dstBPR = width * 4
        var data = Data(count: rows * dstBPR)
        data.withUnsafeMutableBytes { dst in
            guard let d = dst.baseAddress else { return }
            for i in 0..<rows {
                memcpy(d.advanced(by: i * dstBPR), base.advanced(by: (r0 + i) * bpr), dstBPR)
            }
        }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: width, height: rows, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: dstBPR, space: colorSpace,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// 拼出整张长图。maxRowsFromBottom 不为空时只拼最底部的若干行（用于预览）。
    func makeImage(maxRowsFromBottom: Int? = nil) -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        var parts: [CGImage] = []
        if let limit = maxRowsFromBottom {
            var total = footerStrip?.height ?? 0
            for s in strips.reversed() {
                parts.insert(s, at: 0)
                total += s.height
                if total >= limit { break }
            }
        } else {
            if let headerStrip { parts.append(headerStrip) }
            parts += strips
        }
        if let footerStrip { parts.append(footerStrip) }
        let total = parts.reduce(0) { $0 + $1.height }
        guard total > 0,
              let ctx = CGContext(data: nil, width: width, height: total, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        var y = total
        for s in parts {
            y -= s.height
            ctx.draw(s, in: CGRect(x: 0, y: y, width: width, height: s.height))
        }
        return ctx.makeImage()
    }

    /// 整张长图等比缩到 maxWidth × maxHeight（像素）以内，用于预览。
    func makeThumbnail(maxWidth: Int, maxHeight: Int) -> CGImage? {
        var parts: [CGImage] = []
        if let headerStrip { parts.append(headerStrip) }
        parts += strips
        if let footerStrip { parts.append(footerStrip) }
        let total = parts.reduce(0) { $0 + $1.height }
        guard width > 0, total > 0, maxWidth > 0, maxHeight > 0 else { return nil }
        let s = min(1, CGFloat(maxWidth) / CGFloat(width), CGFloat(maxHeight) / CGFloat(total))
        let w = max(1, Int((CGFloat(width) * s).rounded()))
        let h = max(1, Int((CGFloat(total) * s).rounded()))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.scaleBy(x: CGFloat(w) / CGFloat(width), y: CGFloat(h) / CGFloat(total))
        var y = total
        for p in parts {
            y -= p.height
            ctx.draw(p, in: CGRect(x: 0, y: y, width: width, height: p.height))
        }
        return ctx.makeImage()
    }
}
