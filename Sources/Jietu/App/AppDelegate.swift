import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var cleanupTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()
        setupStatusItem()

        HotKeyManager.shared.onCapture = { CaptureCoordinator.shared.hotKeyPressed() }
        registerHotKey()
        NotificationCenter.default.addObserver(forName: .shortcutsChanged, object: nil, queue: .main) { [weak self] _ in
            self?.registerHotKey()
        }

        RecordingSession.onStatusChange = { [weak self] text in self?.updateStatusItem(recordingText: text) }

        LoginItem.initializeIfNeeded()
        Paths.cleanupOldFiles()
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in Paths.cleanupOldFiles() }

        if !Permission.screenRecording.isGranted {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { OnboardingWindowController.shared.show() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindowController.shared.show()
        return true
    }

    private func registerHotKey() {
        let combo = Prefs.shared.shortcut(.capture)
        if !HotKeyManager.shared.register(combo) {
            NSLog("全局快捷键 \(combo.displayString) 注册失败，可能已被其他应用占用")
        }
    }

    // MARK: 菜单栏

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusItem(recordingText: nil)

        let menu = NSMenu()
        menu.addItem(withTitle: "设置…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出", action: #selector(quit), keyEquivalent: "q").target = self
        statusItem.menu = menu
    }

    private func updateStatusItem(recordingText: String?) {
        guard let button = statusItem.button else { return }
        if let text = recordingText {
            button.image = nil
            let s = NSMutableAttributedString(string: "● ", attributes: [
                .foregroundColor: NSColor.systemRed, .font: NSFont.menuBarFont(ofSize: 0),
            ])
            s.append(NSAttributedString(string: text, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
            ]))
            button.attributedTitle = s
        } else {
            button.attributedTitle = NSAttributedString(string: "")
            let image = NSImage(systemSymbolName: "scissors", accessibilityDescription: "截图录屏")
            image?.isTemplate = true
            button.image = image
        }
    }

    @objc private func openSettings() { SettingsWindowController.shared.show() }
    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: 主菜单
    // 菜单栏应用不显示主菜单，但 ⌘C / ⌘V / ⌘A 等快捷键依赖它，所以仍然建一个。

    private func setupMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(withTitle: "关闭", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        NSApp.mainMenu = main
    }
}

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static var requiresApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    /// 首次启动时默认打开开机自动启动。
    static func initializeIfNeeded() {
        guard !Prefs.shared.didInitializeLoginItem else { return }
        Prefs.shared.didInitializeLoginItem = true
        _ = setEnabled(true)
    }

    @discardableResult
    static func setEnabled(_ enabled: Bool) -> String? {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return nil
        } catch {
            NSLog("开机自动启动设置失败：\(error)")
            return error.localizedDescription
        }
    }
}
