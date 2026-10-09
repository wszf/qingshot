import AppKit
import Carbon

private final class FakeHotkeys:HotkeyRegistering {
    var registered:[CaptureAction:CaptureShortcut] = [:]
    var blocked:CaptureShortcut?
    func register(_ shortcut:CaptureShortcut,action:CaptureAction) -> OSStatus {
        if shortcut == blocked || registered.values.contains(shortcut) {return OSStatus(eventHotKeyExistsErr)}
        registered[action] = shortcut;return noErr
    }
    func unregister(_ action:CaptureAction) {registered[action] = nil}
}
@MainActor enum ShortcutTests {
    static func run() {
        var failures = 0
        func check(_ ok:Bool,_ label:String) {print("\(ok ? "PASS" : "FAIL") \(label)");if !ok {failures += 1}}
        let defaults = UserDefaults(suiteName:"local.qingshot.test.\(UUID().uuidString)")!
        // Only remove this test's keys; never touch the actual application preferences.
        defer {defaults.removeObject(forKey:ShortcutStore.defaultsKey)}
        let system = FakeHotkeys(), store = ShortcutStore(defaults:defaults,system:system)
        store.activate()
        check(system.registered.count == 3,"Register defaults")
        let custom = CaptureShortcut(keyCode:UInt32(kVK_ANSI_8),modifiers:UInt32(controlKey | shiftKey))
        check(store.update(.area,to:custom) && system.registered[.area] == custom,"Replace hotkey immediately")
        check(!system.registered.values.contains(CaptureAction.area.defaultShortcut),"Old registration released")
        check(!store.update(.window,to:custom) && system.registered[.window] == CaptureAction.window.defaultShortcut,"Reject duplicates without changing original")
        let blocked = CaptureShortcut(keyCode:UInt32(kVK_ANSI_9),modifiers:UInt32(controlKey | shiftKey));system.blocked = blocked
        check(!store.update(.area,to:blocked) && store.shortcut(.area) == custom && system.registered[.area] == custom,"Registration conflict rolls back")
        let reloaded = ShortcutStore(defaults:defaults,system:FakeHotkeys())
        check(reloaded.shortcut(.area) == custom,"Persist successful setting, not rejected candidate")
        check(!store.update(.area,to:CaptureShortcut(keyCode:0,modifiers:0)),"Reject unmodified typing key")
        check(!store.update(.area,to:CaptureShortcut(keyCode:8,modifiers:UInt32(cmdKey))),"Protect Command-C")
        store.clear(.full)
        check(store.shortcut(.full) == nil && system.registered[.full] == nil && ShortcutStore(defaults:defaults,system:FakeHotkeys()).shortcut(.full) == nil,"Disable persists across restart")
        store.beginRecording(.area)
        check(system.registered.isEmpty,"Suspend capture during key recording")
        store.cancelRecording()
        check(store.recording == nil && system.registered[.area] == custom,"Cancel restores original registrations")
        system.blocked = CaptureAction.area.defaultShortcut
        check(!store.restoreDefaults() && system.registered[.area] == custom && store.shortcut(.full) == nil,"Default restore is transactional on conflict")
        system.blocked = nil
        check(store.restoreDefaults() && system.registered.count == 3 && store.display(.area) == "⌃⇧2","Restore defaults and display labels")
        exit(failures == 0 ? 0 : 1)
    }
}
