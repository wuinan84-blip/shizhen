import AppKit
import Carbon.HIToolbox

/// 用 Carbon 注册全局快捷键（不需要辅助功能权限）。
final class HotKeyManager {
    static let shared = HotKeyManager()

    var onCapture: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let signature: OSType = 0x4A_54_53_43 // "JTSC"

    private init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ -> OSStatus in
            DispatchQueue.main.async { HotKeyManager.shared.onCapture?() }
            return noErr
        }, 1, &spec, nil, &handlerRef)
    }

    /// 注册（或重新注册）截图快捷键。返回是否成功。
    @discardableResult
    func register(_ combo: KeyCombo) -> Bool {
        unregister()
        let id = EventHotKeyID(signature: signature, id: 1)
        let status = RegisterEventHotKey(UInt32(combo.keyCode), combo.carbonModifiers, id,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        return status == noErr
    }

    func unregister() {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref) }
        hotKeyRef = nil
    }

    /// 检查组合键是否已被其他应用或系统快捷键占用。
    /// 方法：先查系统快捷键表，再临时注册一次看是否失败。调用时本应用的快捷键需要先注销。
    func isTakenBySystemOrOtherApp(_ combo: KeyCombo) -> Bool {
        if isSystemShortcut(combo) { return true }
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: signature, id: 99)
        let status = RegisterEventHotKey(UInt32(combo.keyCode), combo.carbonModifiers, id,
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref { UnregisterEventHotKey(ref); return false }
        return true
    }

    private func isSystemShortcut(_ combo: KeyCombo) -> Bool {
        var unmanaged: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&unmanaged) == noErr, let array = unmanaged?.takeRetainedValue() as? [[String: Any]] else {
            return false
        }
        for item in array {
            guard (item[kHISymbolicHotKeyEnabled as String] as? Bool) == true,
                  let code = item[kHISymbolicHotKeyCode as String] as? Int,
                  let mods = item[kHISymbolicHotKeyModifiers as String] as? Int else { continue }
            if code == Int(combo.keyCode) && UInt32(mods) & 0xFF00 == combo.carbonModifiers & 0xFF00 {
                return true
            }
        }
        return false
    }
}
