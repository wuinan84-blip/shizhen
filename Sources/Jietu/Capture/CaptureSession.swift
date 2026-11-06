import AppKit
import AVFoundation
import UniformTypeIdentifiers

/// 全局快捷键入口：决定是否开始新的截图 / 录屏。
final class CaptureCoordinator {
    static let shared = CaptureCoordinator()

    fileprivate(set) var session: CaptureSession?
    private var starting = false

    func hotKeyPressed() {
        // 录制中、滚动截图中再按快捷键：不做任何操作
        if RecordingSession.isActive || ScrollCaptureController.current != nil { return }
        if session != nil || starting { return }
        guard Permission.screenRecording.isGranted else {
            PermissionAlert.show(.screenRecording, message: "截图和录屏需要「屏幕录制」权限。")
            return
        }
        starting = true
        let screen = ScreenCapturer.screenUnderMouse()
        Task { @MainActor in
            defer { self.starting = false }
            do {
                self.session = try await CaptureSession.start(on: screen, mode: .screenshot)
            } catch {
                NSLog("截图启动失败：\(error)")
                PermissionAlert.show(.screenRecording, message: "无法获取屏幕画面（\(error.localizedDescription)）。请确认已授予「屏幕录制」权限。")
            }
        }
    }

    fileprivate func ended(_ s: CaptureSession) {
        if session === s { session = nil }
    }
}

/// 一次截图 / 录屏的选区阶段：遮罩窗口、跟随显示器、结束方式。
final class CaptureSession: OverlayViewDelegate {
    private(set) var screen: NSScreen
    private var window: OverlayWindow
    private var overlay: OverlayView
    private var followTimer: Timer?
    private var switchingScreen = false
    private var ended = false
    private var screenObserver: NSObjectProtocol?

    // 录屏倒计时
    private var countdownTimer: Timer?
    private var countdownValue = 0
    private var preparedRecording: RecordingSession?
    private var countdownDone = false
    private var countdownToken = UUID()
    private var recordingOptions = RecordingOptions()

    @MainActor
    static func start(on screen: NSScreen, mode: CaptureMode) async throws -> CaptureSession {
        let image = try await ScreenCapturer.captureScreen(screen)
        let windows = ScreenCapturer.windowRects(on: screen)
        return CaptureSession(screen: screen, image: image, windows: windows, mode: mode)
    }

    private init(screen: NSScreen, image: CGImage, windows: [CGRect], mode: CaptureMode) {
        self.screen = screen
        (window, overlay) = Self.makeOverlay(screen: screen, image: image, windows: windows, mode: mode)
        overlay.delegate = self
        present()
        followTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in self?.followMouse() }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            guard let self, self.preparedRecording == nil, ScrollCaptureController.current == nil else { return }
            self.end()
        }
    }

    private static func makeOverlay(screen: NSScreen, image: CGImage, windows: [CGRect], mode: CaptureMode) -> (OverlayWindow, OverlayView) {
        let window = OverlayWindow(screen: screen)
        let overlay = OverlayView(frame: CGRect(origin: .zero, size: screen.frame.size), screenImage: image,
                                  scale: screen.backingScaleFactor, windowRects: windows, safeTop: screen.safeAreaInsets.top)
        overlay.setMode(mode)
        window.contentView = overlay
        return (window, overlay)
    }

    private func present() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(overlay)
        let p = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        overlay.updateHover(at: overlay.convert(p, from: nil))
        NSCursor.crosshair.set()
    }

    // MARK: 跟随鼠标切换显示器（只在还没确定选区时）

    private func followMouse() {
        guard !ended, !switchingScreen, overlay.phase == .hovering else { return }
        let target = ScreenCapturer.screenUnderMouse()
        guard ScreenCapturer.displayID(target) != ScreenCapturer.displayID(screen) else { return }
        switchingScreen = true
        let mode = overlay.mode
        Task { @MainActor in
            defer { self.switchingScreen = false }
            guard let image = try? await ScreenCapturer.captureScreen(target), !self.ended,
                  self.overlay.phase == .hovering else { return }
            let windows = ScreenCapturer.windowRects(on: target)
            let old = self.window
            self.screen = target
            (self.window, self.overlay) = Self.makeOverlay(screen: target, image: image, windows: windows, mode: mode)
            self.overlay.delegate = self
            self.present()
            old.orderOut(nil)
            old.close()
        }
    }

    // MARK: 结束

    func end() {
        guard !ended else { return }
        ended = true
        followTimer?.invalidate()
        countdownTimer?.invalidate()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        overlay.editor.commitText()
        window.orderOut(nil)
        window.close()
        HoverTip.shared.hide()
        TextResultPanelController.lowerAll()
        CaptureCoordinator.shared.ended(self)
        NSCursor.arrow.set()
    }

    /// 面板关闭后把键盘焦点还给遮罩（Esc、回车等快捷键才能继续用）。
    func refocus() {
        guard !ended, !window.ignoresMouseEvents else { return }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(overlay)
    }

    func overlayCancel() { end() }

    func overlayConfirm() {
        guard let image = overlay.renderSelection() else { return }
        Clipboard.writeImage(image, scale: overlay.scale)
        end()
    }

    func overlaySave() {
        guard let image = overlay.renderSelection() else { return }
        guard let url = SavePanel.run(defaultName: Paths.screenshotName(), type: .png, level: .capturePanel) else {
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(overlay)
            return
        }
        if let data = ImageFile.pngData(image, scale: overlay.scale) {
            do { try data.write(to: url) } catch {
                Alerts.info("保存失败", info: error.localizedDescription, level: .capturePanel)
                return
            }
        }
        end()
    }

    func overlayConfirmModeSwitch() -> Bool {
        let ok = Alerts.confirm("切换到录屏会清空已画的标注", info: "确定要切换吗？", ok: "清空并切换", level: .capturePanel)
        window.makeKeyAndOrderFront(nil)
        return ok
    }

    // MARK: 提取文字 / 翻译

    func overlayRecognizeText(translate: Bool) {
        guard let image = overlay.renderSelection() else { return }
        TextResultPanelController.show(image: image, translate: translate, near: overlay.selectionInScreen(), on: screen)
    }

    // MARK: 滚动截图

    func overlayScrollCapture() {
        guard overlay.editor.isEmpty else { return }
        let rect = overlay.selection
        overlay.setLive(true, locked: false)
        window.ignoresMouseEvents = true
        followTimer?.invalidate()
        ScrollCaptureController.start(screen: screen, rect: rect, anchor: overlay.selectionInScreen()) { [weak self] result in
            guard let self else { return }
            switch result {
            case .cancelled:
                self.window.ignoresMouseEvents = false
                self.overlay.setLive(false, locked: false)
                NSApp.activate(ignoringOtherApps: true)
                self.window.makeKeyAndOrderFront(nil)
                self.window.makeFirstResponder(self.overlay)
            case .finished(let image, let scale):
                self.end()
                LongImageEditorController.open(image: image, scale: scale)
            }
        }
    }

    // MARK: 录屏

    func overlayRequestMicrophone(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .notDetermined:
            // 系统授权弹窗在遮罩下面会看不到，临时降低遮罩层级
            window.level = .normal
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    self.window.level = .captureOverlay
                    NSApp.activate(ignoringOtherApps: true)
                    self.window.makeKeyAndOrderFront(nil)
                    completion(granted)
                    if !granted {
                        PermissionAlert.show(.microphone, message: "没有麦克风权限，无法录制麦克风声音。", level: .capturePanel)
                    }
                }
            }
        default:
            completion(false)
            PermissionAlert.show(.microphone, message: "没有麦克风权限，无法录制麦克风声音。", level: .capturePanel)
            window.makeKeyAndOrderFront(nil)
        }
    }

    func overlayStartRecording(_ options: RecordingOptions) {
        recordingOptions = options
        let rect = overlay.selection
        overlay.setLive(true, locked: true)
        countdownDone = false
        countdownValue = 3
        overlay.showCountdown(3)
        followTimer?.invalidate()

        // 倒计时期间就启动采集（遮罩窗口不会被录进去），倒计时结束后才开始写入
        let screen = self.screen
        let token = UUID()
        countdownToken = token
        Task { @MainActor in
            do {
                let session = try await RecordingSession.prepare(screen: screen, rect: rect, options: options)
                guard token == self.countdownToken, self.countdownTimer != nil || self.countdownDone else {
                    session.discard()   // 已经取消
                    return
                }
                self.preparedRecording = session
                if self.countdownDone { self.beginRecording() }
            } catch {
                guard token == self.countdownToken else { return }
                self.cancelCountdown()
                Alerts.info("无法开始录制", info: error.localizedDescription, level: .capturePanel)
            }
        }

        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            self.countdownValue -= 1
            if self.countdownValue > 0 {
                self.overlay.showCountdown(self.countdownValue)
            } else {
                t.invalidate()
                self.countdownTimer = nil
                self.countdownDone = true
                self.overlay.showCountdown(nil)
                if self.preparedRecording != nil { self.beginRecording() }
            }
        }
    }

    private func beginRecording() {
        guard let session = preparedRecording else { return }
        preparedRecording = nil
        end()
        session.begin()
    }

    func overlayCancelCountdown() { cancelCountdown() }

    private func cancelCountdown() {
        countdownToken = UUID()
        countdownTimer?.invalidate()
        countdownTimer = nil
        countdownDone = false
        preparedRecording?.discard()
        preparedRecording = nil
        overlay.showCountdown(nil)
        overlay.setLive(false, locked: false)
        window.makeFirstResponder(overlay)
    }
}
