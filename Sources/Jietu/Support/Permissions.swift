import AppKit
import AVFoundation
import ApplicationServices

enum Permission: CaseIterable {
    case screenRecording, microphone, accessibility

    var title: String {
        switch self {
        case .screenRecording: return "屏幕录制"
        case .microphone: return "麦克风"
        case .accessibility: return "辅助功能"
        }
    }

    var purpose: String {
        switch self {
        case .screenRecording: return "截图、录屏、识别窗口位置（必需）"
        case .microphone: return "录视频时录制麦克风声音"
        case .accessibility: return "滚动截图中的「自动滚动」"
        }
    }

    var isGranted: Bool {
        switch self {
        case .screenRecording: return CGPreflightScreenCaptureAccess()
        case .microphone: return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        case .accessibility: return AXIsProcessTrusted()
        }
    }

    var settingsURL: URL {
        let anchor: String
        switch self {
        case .screenRecording: anchor = "Privacy_ScreenCapture"
        case .microphone: anchor = "Privacy_Microphone"
        case .accessibility: anchor = "Privacy_Accessibility"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }

    func openSettings() {
        NSWorkspace.shared.open(settingsURL)
    }

    /// 触发系统的授权请求（会把本应用加入系统设置里的列表）。
    func request(completion: ((Bool) -> Void)? = nil) {
        switch self {
        case .screenRecording:
            let ok = CGRequestScreenCaptureAccess()
            completion?(ok)
        case .microphone:
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                DispatchQueue.main.async { completion?(ok) }
            }
        case .accessibility:
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            completion?(AXIsProcessTrustedWithOptions(options))
        }
    }
}

enum AppRelauncher {
    /// 重启应用（屏幕录制授权后需要重启才生效）。
    static func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.6; /usr/bin/open -n \"\(path)\""]
        try? task.run()
        NSApp.terminate(nil)
    }
}

/// 弹出说明框，提供「去系统设置开启」按钮。
enum PermissionAlert {
    static func show(_ permission: Permission, message: String? = nil, level: NSWindow.Level? = nil) {
        let alert = NSAlert()
        alert.messageText = "需要「\(permission.title)」权限"
        var info = message ?? "\(permission.purpose)需要这项权限。"
        if permission == .screenRecording {
            info += "\n\n授权后，macOS 通常需要重启本应用才会生效。"
        }
        alert.informativeText = info
        alert.addButton(withTitle: "去系统设置开启")
        if permission == .screenRecording { alert.addButton(withTitle: "已授权，重启应用") }
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        if let level { alert.window.level = level }
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            permission.request()
            permission.openSettings()
        } else if permission == .screenRecording && response == .alertSecondButtonReturn {
            AppRelauncher.relaunch()
        }
    }
}
