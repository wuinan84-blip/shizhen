import AppKit
import AVFoundation
import Combine
import ServiceManagement
import SwiftUI

final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 480),
                             styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "拾帧 设置"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView())
            w.center()
            w.delegate = self
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // 关闭设置时确保全局快捷键处于注册状态
        NotificationCenter.default.post(name: .shortcutsChanged, object: nil)
    }
}

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralTab().tabItem { Text("通用") }
            ShortcutsTab().tabItem { Text("快捷键") }
            TranslateTab().tabItem { Text("翻译") }
            PermissionsTab().tabItem { Text("权限") }
            AboutTab().tabItem { Text("关于") }
        }
        .padding(12)
        .frame(width: 600, height: 480)
    }
}

// MARK: - 通用

struct GeneralTab: View {
    @State private var enabled = LoginItem.isEnabled
    @State private var needsApproval = LoginItem.requiresApproval
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                Toggle("开机自动启动", isOn: Binding(get: { enabled }, set: { value in
                    error = LoginItem.setEnabled(value)
                    enabled = LoginItem.isEnabled
                    needsApproval = LoginItem.requiresApproval
                }))
                if needsApproval {
                    HStack {
                        Text("需要在「系统设置 → 通用 → 登录项」中允许本应用。").font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button("打开登录项设置") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
                if let error { Text("设置失败：\(error)").font(.callout).foregroundStyle(.red) }
            }
            Section {
                LabeledContent("开始截图 / 录屏", value: Prefs.shared.shortcut(.capture).displayString)
                Text("按下快捷键后，在屏幕顶部选择「截图」或「录屏」。快捷键可在「快捷键」中修改。")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 快捷键

final class KeyRecorderMonitor: ObservableObject {
    private var monitor: Any?

    func start(_ handler: @escaping (NSEvent) -> Void) {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handler(event)
            return nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    deinit { stop() }
}

struct ShortcutsTab: View {
    @ObservedObject private var prefs = Prefs.shared
    @State private var recording: ShortcutAction?
    @State private var messages: [ShortcutAction: String] = [:]

    var body: some View {
        Form {
            Section("全局") { row(.capture) }
            Section("截图中") {
                row(.cancel)
                row(.confirm)
                row(.save)
                row(.undo)
                row(.redo)
            }
            Section("录屏") { row(.cancelCountdown) }
            Section {
                HStack {
                    Text("正在输入文字或标签内容时，回车是换行、Esc 是结束输入。").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("恢复默认") {
                        prefs.resetShortcuts()
                        messages = [:]
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func row(_ action: ShortcutAction) -> some View {
        LabeledContent(action.title) {
            VStack(alignment: .trailing, spacing: 4) {
                ShortcutRecorderButton(action: action, recording: $recording) { combo in
                    messages[action] = validateAndSave(action, combo)
                }
                if let m = messages[action] {
                    Text(m).font(.caption).foregroundStyle(.red)
                }
            }
        }
    }

    /// 返回错误信息；nil 表示已保存。
    private func validateAndSave(_ action: ShortcutAction, _ combo: KeyCombo) -> String? {
        if combo == prefs.shortcut(action) { return nil }
        if action.isGlobal {
            let flags = combo.modifierFlags
            let isFunctionKey = KeyCombo.keyName(combo.keyCode).hasPrefix("F")
            if !isFunctionKey && flags.intersection([.command, .option, .control]).isEmpty {
                return "全局快捷键需要包含 ⌃、⌥ 或 ⌘，未保存"
            }
        }
        if let other = prefs.internalConflict(combo, for: action) {
            return "与「\(other.title)」冲突，未保存"
        }
        if action.isGlobal && HotKeyManager.shared.isTakenBySystemOrOtherApp(combo) {
            return "\(combo.displayString) 已被系统或其他应用占用，未保存"
        }
        prefs.setShortcut(combo, for: action)
        return nil
    }
}

struct ShortcutRecorderButton: View {
    let action: ShortcutAction
    @Binding var recording: ShortcutAction?
    let onRecord: (KeyCombo) -> Void
    @ObservedObject private var prefs = Prefs.shared
    @StateObject private var monitor = KeyRecorderMonitor()

    private var isRecording: Bool { recording == action }

    var body: some View {
        Button {
            isRecording ? stop() : start()
        } label: {
            Text(isRecording ? "请按下新的快捷键…" : prefs.shortcut(action).displayString)
                .frame(minWidth: 140)
                .foregroundStyle(isRecording ? Color.accentColor : Color.primary)
        }
        .onChange(of: recording) { _, newValue in
            if newValue != action { monitor.stop() }
        }
        .onDisappear { stop() }
    }

    private func start() {
        recording = action
        if action.isGlobal { HotKeyManager.shared.unregister() }
        monitor.start { event in
            let combo = KeyCombo(event: event)
            stop()
            onRecord(combo)
        }
    }

    private func stop() {
        monitor.stop()
        if recording == action { recording = nil }
        if action.isGlobal { NotificationCenter.default.post(name: .shortcutsChanged, object: nil) }
    }
}

// MARK: - 翻译

struct TranslateTab: View {
    @ObservedObject private var prefs = Prefs.shared
    @State private var appID = BaiduTranslator.appID
    @State private var secret = BaiduTranslator.secret
    @State private var showPrivacyAlert = false
    @State private var testing = false
    @State private var testResult: String?
    @State private var testOK = false

    var body: some View {
        Form {
            Section {
                Picker("翻译引擎", selection: Binding(get: { prefs.translateEngine }, set: { value in
                    if value == .baidu && prefs.translateEngine != .baidu { showPrivacyAlert = true } else { prefs.translateEngine = value }
                })) {
                    Text("系统离线翻译（默认）").tag(TranslateEngine.apple)
                    Text("百度翻译").tag(TranslateEngine.baidu)
                }
                .pickerStyle(.radioGroup)
                Text(prefs.translateEngine == .apple
                     ? "使用 macOS 自带的离线翻译，统一翻译成中文。第一次翻译某种语言时，系统需要联网下载语言包，之后完全离线。"
                     : "识别出的文字会发送到百度服务器进行翻译。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if prefs.translateEngine == .baidu {
                Section("百度翻译密钥（保存在系统钥匙串中）") {
                    TextField("APP ID", text: $appID)
                        .onChange(of: appID) { _, v in Keychain.set(v.trimmingCharacters(in: .whitespaces), for: "appid") }
                    SecureField("密钥", text: $secret)
                        .onChange(of: secret) { _, v in Keychain.set(v.trimmingCharacters(in: .whitespaces), for: "key") }
                    HStack {
                        Button(testing ? "测试中…" : "测试") { test() }.disabled(testing)
                        if let testResult {
                            Text(testResult).font(.callout).foregroundStyle(testOK ? .green : .red)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Section {
                    Text("在百度翻译开放平台注册开发者即可免费获得 APP ID 和密钥。免费额度：未认证每月 5 万字符，个人实名认证后每月 100 万字符；超出后按 49 元 / 百万字符计费。本应用不统计额度，需要时请在百度翻译管理控制台开启余额提醒。")
                        .font(.callout).foregroundStyle(.secondary)
                    Link("打开百度翻译开放平台", destination: URL(string: "https://fanyi-api.baidu.com/")!)
                }
            }
        }
        .formStyle(.grouped)
        .alert("切换到百度翻译？", isPresented: $showPrivacyAlert) {
            Button("切换") { prefs.translateEngine = .baidu }
            Button("取消", role: .cancel) {}
        } message: {
            Text("使用百度翻译时，识别出的文字会发送到百度服务器。")
        }
    }

    private func test() {
        testing = true
        testResult = nil
        Task { @MainActor in
            do {
                let r = try await BaiduTranslator.translate(lines: ["Hello, world!"])
                testOK = true
                testResult = "连接成功：Hello, world! → \(r)"
            } catch {
                testOK = false
                testResult = error.localizedDescription
            }
            testing = false
        }
    }
}

// MARK: - 权限

struct PermissionsTab: View {
    @State private var tick = 0
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                ForEach(Permission.allCases, id: \.self) { p in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.title)
                            Text(p.purpose).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if p.isGranted {
                            Label("已授权", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            Text("未授权").foregroundStyle(.red)
                            Button("去系统设置开启") {
                                if p == .microphone && AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                                    p.request { _ in tick += 1 }
                                } else {
                                    p.request()
                                    p.openSettings()
                                }
                            }
                        }
                    }
                    .id("\(p.title)-\(tick)")
                }
            }
            Section {
                HStack {
                    Text("屏幕录制授权后，需要重启本应用才会生效。").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("重启应用") { AppRelauncher.relaunch() }
                }
            }
        }
        .formStyle(.grouped)
        .onReceive(timer) { _ in tick += 1 }
    }
}

// MARK: - 关于

struct AboutTab: View {
    private var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(v)（\(b)）"
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "scissors").font(.system(size: 40)).foregroundStyle(Color.accentColor)
            Text("拾帧").font(.title2.bold())
            Text("版本 \(version)").foregroundStyle(.secondary)
            Text("默认所有处理都在本机完成，不联网、不收集任何使用数据。\n只有在「翻译」中切换到百度翻译后，才会把识别出的文字发送给百度。")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
