import AppKit
import SwiftUI

/// 首次启动的权限引导：屏幕录制是必需权限。
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    static let shared = OnboardingWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 460, height: 360),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "欢迎使用拾帧"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: OnboardingView(close: { [weak self] in self?.window?.close() }))
            w.center()
            w.delegate = self
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        Prefs.shared.didShowOnboarding = true
    }
}

struct OnboardingView: View {
    let close: () -> Void
    @State private var granted = Permission.screenRecording.isGranted
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "scissors").font(.system(size: 28)).foregroundStyle(Color.accentColor)
                Text("拾帧需要「屏幕录制」权限").font(.title3.bold())
            }
            Text("截图、录屏和识别窗口位置都需要读取屏幕画面。所有处理都在本机完成。")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                step(1, "点击下方「去授权」，在弹出的系统设置里打开「拾帧」的开关。")
                step(2, "回到这里点击「重启应用」（macOS 需要重启应用后权限才生效）。")
                step(3, "按 \(Prefs.shared.shortcut(.capture).displayString) 开始截图或录屏。")
            }
            if granted {
                Label("已检测到授权", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            }
            Spacer()
            HStack {
                Button("稍后") { close() }
                Spacer()
                Button("去授权") {
                    Permission.screenRecording.request()
                    Permission.screenRecording.openSettings()
                }
                Button("重启应用") { AppRelauncher.relaunch() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 460, height: 340)
        .onReceive(timer) { _ in granted = Permission.screenRecording.isGranted }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(n)").font(.callout.bold()).foregroundStyle(.white)
                .frame(width: 20, height: 20).background(Circle().fill(Color.accentColor))
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}
