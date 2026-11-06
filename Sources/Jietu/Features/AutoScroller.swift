import CoreGraphics
import CoreVideo
import QuartzCore

/// 自动滚动的步进控制：每滚一步，等画面停稳后只拼接停稳的那一帧，确认接上了再滚下一步。
/// 不同应用对模拟滚轮的实际滚动距离不一样（有的会放大好几倍），所以按实测距离调整步长；
/// 滚过头接不上时，往回滚同样的距离回到能接上的位置，再用更小的步长继续。
/// 只在同一个串行队列上使用。
final class AutoScroller {
    enum StopReason { case reachedBottom, noResponse, failed, limitReached }
    enum Action { case none, scroll(CGFloat), stop(StopReason) }

    /// 发出滚动后至少等这么久，避免应用还没响应就判定为停稳。
    static let minWait: CFTimeInterval = 0.3
    /// 画面连续这么久没有变化，视为停稳。
    static let minQuiet: CFTimeInterval = 0.2
    /// 画面一直在变（选区里有动画）时最多等这么久。
    static let maxWait: CFTimeInterval = 1.5
    /// 每步希望页面实际滚动的距离占选区高度的比例，其余部分用来对齐。
    static let targetRatio: CGFloat = 0.3
    /// 连续这么多步没有滚动，视为到底。
    static let idleStepsToStop = 5
    /// 连续滚过头这么多次仍接不上，放弃。
    static let maxRetries = 3

    private let stitcher: Stitcher
    private let scale: CGFloat
    private let frameHeight: CGFloat
    private let minAmount: CGFloat
    private let maxAmount: CGFloat
    /// 每步请求滚动的距离（点）。
    private(set) var amount: CGFloat

    private enum Phase { case idle, forward, reverse }
    private var phase = Phase.idle
    private var pending: CVPixelBuffer?
    private var lastSignature: UInt64?
    private var lastChange: CFTimeInterval = 0
    private var stepStart: CFTimeInterval = 0
    private var topBeforeStep = 0
    private var idleSteps = 0
    private var retries = 0
    private var totalMoved = 0
    /// 实测的「实际滚动像素 / 请求滚动像素」。
    private var measuredRatio: CGFloat?

    /// viewHeight：选区高度（点）；scale：像素 / 点。
    init(stitcher: Stitcher, viewHeight: CGFloat, scale: CGFloat) {
        self.stitcher = stitcher
        self.scale = scale
        frameHeight = viewHeight * scale
        minAmount = max(6, viewHeight * 0.03)
        maxAmount = max(minAmount, viewHeight * 0.6)
        amount = max(minAmount, viewHeight * 0.25)
    }

    var isRunning: Bool { phase != .idle }

    func frameArrived(_ pb: CVPixelBuffer, at now: CFTimeInterval) {
        let sig = Stitcher.signature(pb)
        if sig != lastSignature {
            lastSignature = sig
            lastChange = now
        }
        pending = pb
    }

    func start(at now: CFTimeInterval) -> Action {
        idleSteps = 0
        retries = 0
        totalMoved = 0
        return step(.forward, distance: amount, now: now)
    }

    func stop() {
        phase = .idle
        pending = nil
    }

    /// 定时调用。返回这次拼接的结果（没到拼接时机为 nil）和下一步动作。
    func tick(at now: CFTimeInterval) -> (Stitcher.AddResult?, Action) {
        guard phase != .idle else { return (nil, .none) }
        let elapsed = now - stepStart
        let settled = elapsed >= Self.minWait && now - lastChange >= Self.minQuiet
        guard settled || elapsed >= Self.maxWait else { return (nil, .none) }

        var result = Stitcher.AddResult.unchanged
        if let pb = pending {
            let expected = phase == .reverse ? 0 : measuredRatio.map { Int((amount * scale * $0).rounded()) }
            result = stitcher.add(pb, hint: expected)
            pending = nil
        }

        switch result {
        case .limitReached:
            phase = .idle
            return (result, .stop(.limitReached))

        case .noMatch:
            guard phase == .forward, retries < Self.maxRetries else {
                phase = .idle
                return (result, .stop(.failed))
            }
            retries += 1
            let back = amount
            amount = max(minAmount, amount / 2)
            return (result, step(.reverse, distance: -back, now: now))

        case .grew, .unchanged:
            if phase == .forward {
                let moved = stitcher.viewTop - topBeforeStep
                if moved > 0 {
                    idleSteps = 0
                    retries = 0
                    totalMoved += moved
                    adapt(moved: moved)
                } else {
                    idleSteps += 1
                    if idleSteps >= Self.idleStepsToStop {
                        phase = .idle
                        return (result, .stop(totalMoved > 0 ? .reachedBottom : .noResponse))
                    }
                }
            }
            return (result, step(.forward, distance: amount, now: now))
        }
    }

    private func step(_ p: Phase, distance: CGFloat, now: CFTimeInterval) -> Action {
        phase = p
        stepStart = now
        topBeforeStep = stitcher.viewTop
        pending = nil
        return .scroll(distance)
    }

    /// 按实测的「实际滚动像素 / 请求滚动像素」调整步长，让每步实际滚动接近 targetRatio。
    private func adapt(moved: Int) {
        let ratio = CGFloat(moved) / (amount * scale)
        guard ratio > 0 else { return }
        measuredRatio = ratio
        let desired = frameHeight * Self.targetRatio / ratio / scale
        let bounded = min(max(desired, amount * 0.25), amount * 2)
        amount = min(max(bounded, minAmount), maxAmount)
    }
}
