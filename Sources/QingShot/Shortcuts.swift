import AppKit
import SwiftUI
import Carbon

enum CaptureAction: String, CaseIterable, Identifiable {
    case area, window, full
    var id: String { rawValue }
    var title: String { switch self { case .area: return L("区域截图"); case .window: return L("窗口截图"); case .full: return L("全屏截图") } }
    var icon: String { switch self { case .area: return "viewfinder"; case .window: return "macwindow"; case .full: return "display" } }
    var hotkeyID: UInt32 { UInt32(Self.allCases.firstIndex(of:self)! + 1) }
    var defaultShortcut: CaptureShortcut { CaptureShortcut(keyCode:UInt32([kVK_ANSI_2,kVK_ANSI_3,kVK_ANSI_4][Int(hotkeyID)-1]), modifiers:UInt32(controlKey | shiftKey)) }
}
struct CaptureShortcut: Codable, Equatable {
    let keyCode: UInt32
    let modifiers: UInt32
    // Physical key labels: independent of input method and retained across restarts.
    static let keyNames: [UInt32:String] = [0:"A",1:"S",2:"D",3:"F",4:"H",5:"G",6:"Z",7:"X",8:"C",9:"V",11:"B",12:"Q",13:"W",14:"E",15:"R",16:"Y",17:"T",18:"1",19:"2",20:"3",21:"4",22:"6",23:"5",24:"=",25:"9",26:"7",27:"−",28:"8",29:"0",30:"]",31:"O",32:"U",33:"[",34:"I",35:"P",37:"L",38:"J",39:"'",40:"K",41:";",42:"\\",43:",",44:"/",45:"N",46:"M",47:".",49:"Space",50:"`",96:"F5",97:"F6",98:"F7",99:"F3",100:"F8",101:"F9",103:"F11",109:"F10",111:"F12",118:"F4",120:"F2",122:"F1"]
    var display: String {
        var result = ""
        for (flag,symbol) in [(controlKey,"⌃"),(optionKey,"⌥"),(shiftKey,"⇧"),(cmdKey,"⌘")] where modifiers & UInt32(flag) != 0 { result += symbol }
        return result + (keyCode == 49 ? L("空格") : Self.keyNames[keyCode] ?? "?")
    }
    var validationError: String? {
        guard Self.keyNames[keyCode] != nil else {return L("请选择字母、数字、符号、空格或 F1–F12。")}
        guard modifiers & UInt32(cmdKey | controlKey) != 0 else {return L("请至少搭配 Command ⌘ 或 Control ⌃，避免影响正常输入。")}
        guard modifiers & ~UInt32(cmdKey | controlKey | optionKey | shiftKey) == 0 else {return L("不支持这个修饰键组合。")}
        if modifiers == UInt32(cmdKey), [0,6,7,8,9,12,13,14,15,17,31,43,46,48,49].contains(Int(keyCode)) {return L("这个组合是常用的系统或编辑快捷键，请再加 Shift、Option 或 Control。")}
        return nil
    }
    init(keyCode:UInt32, modifiers:UInt32) {self.keyCode = keyCode; self.modifiers = modifiers}
    init(event:NSEvent) {
        keyCode = UInt32(event.keyCode)
        var flags: UInt32 = 0
        for (flag,carbon) in [(NSEvent.ModifierFlags.command,cmdKey),(.control,controlKey),(.option,optionKey),(.shift,shiftKey)] where event.modifierFlags.contains(flag) {flags |= UInt32(carbon)}
        modifiers = flags
    }
}
protocol HotkeyRegistering: AnyObject {
    func register(_ shortcut:CaptureShortcut, action:CaptureAction) -> OSStatus
    func unregister(_ action:CaptureAction)
}
final class CarbonHotkeys: HotkeyRegistering {
    private var refs: [CaptureAction:EventHotKeyRef] = [:]
    func register(_ shortcut:CaptureShortcut, action:CaptureAction) -> OSStatus {
        var ref:EventHotKeyRef?
        let status = RegisterEventHotKey(shortcut.keyCode,shortcut.modifiers,EventHotKeyID(signature:0x51494E47,id:action.hotkeyID),GetApplicationEventTarget(),0,&ref)
        if status == noErr,let ref {refs[action] = ref}
        return status
    }
    func unregister(_ action:CaptureAction) {if let ref = refs.removeValue(forKey:action) {UnregisterEventHotKey(ref)}}
    deinit {for ref in refs.values {UnregisterEventHotKey(ref)}}
}
@MainActor final class ShortcutStore: ObservableObject {
    static let shared = ShortcutStore()
    static let defaultsKey = "captureShortcuts.v1"
    @Published private(set) var bindings: [String:CaptureShortcut]
    @Published private(set) var errors: [String:String] = [:]
    @Published private(set) var recording: CaptureAction?
    @Published var message = L("点击快捷键按钮，然后按下你想使用的组合键。")
    @Published var isError = false
    private let defaults:UserDefaults
    private let system:HotkeyRegistering
    private var monitor:Any?
    private var resignObserver:NSObjectProtocol?
    private var active = false
    init(defaults:UserDefaults = .standard, system:HotkeyRegistering = CarbonHotkeys()) {
        self.defaults = defaults; self.system = system
        let initial = Dictionary(uniqueKeysWithValues:CaptureAction.allCases.map {($0.rawValue,$0.defaultShortcut)})
        if let data = defaults.data(forKey:Self.defaultsKey),let stored = try? JSONDecoder().decode([String:CaptureShortcut].self,from:data) {
            var clean: [String:CaptureShortcut] = [:]
            for action in CaptureAction.allCases {if let shortcut = stored[action.rawValue],shortcut.validationError == nil,!clean.values.contains(shortcut) {clean[action.rawValue] = shortcut}}
            bindings = clean
        } else {bindings = initial}
    }
    func refreshLanguage() {
        cancelRecording()
        message = L("点击快捷键按钮，然后按下你想使用的组合键。")
        isError = false
        for action in CaptureAction.allCases where errors[action.rawValue] != nil {errors[action.rawValue] = L("{0} 被占用，点击更换。",display(action))}
    }
    func shortcut(_ action:CaptureAction) -> CaptureShortcut? {bindings[action.rawValue]}
    func display(_ action:CaptureAction) -> String {shortcut(action)?.display ?? L("未设置")}
    func activate() {guard !active else {return};active = true; registerAll()}
    private func registerAll() {
        errors = [:]
        for action in CaptureAction.allCases {
            if let shortcut = shortcut(action),system.register(shortcut,action:action) != noErr {errors[action.rawValue] = L("{0} 被占用，点击更换。" ,"\(shortcut.display)")}
        }
    }
    private func unregisterAll() {CaptureAction.allCases.forEach {system.unregister($0)}}
    private func persist() {if let data = try? JSONEncoder().encode(bindings) {defaults.set(data,forKey:Self.defaultsKey)}}
    private func fail(_ text:String) {isError = true;message = text}
    @discardableResult func update(_ action:CaptureAction, to candidate:CaptureShortcut?) -> Bool {
        if let candidate {
            if let error = candidate.validationError {fail(error);return false}
            if let other = CaptureAction.allCases.first(where: {$0 != action && shortcut($0) == candidate}) {fail(L("这个组合已用于「{0}」，请选择其他组合。" ,"\(other.title)"));return false}
        }
        let previous = shortcut(action)
        system.unregister(action)
        if let candidate,system.register(candidate,action:action) != noErr {
            if let previous,system.register(previous,action:action) != noErr {errors[action.rawValue] = L("原快捷键也无法注册，请重新设置。")}
            fail(L("{0} 已被系统或其他应用占用，未保存更改。" ,"\(candidate.display)"))
            return false
        }
        bindings[action.rawValue] = candidate;errors[action.rawValue] = nil;persist()
        isError = false;message = candidate == nil ? L("已停用「{0}」的快捷键。" ,"\(action.title)") : L("已保存，立即生效。重启后也会保留。")
        return true
    }
    @discardableResult func restoreDefaults() -> Bool {
        cancelRecording();let old = bindings
        unregisterAll()
        var failed = false
        for action in CaptureAction.allCases {if system.register(action.defaultShortcut,action:action) != noErr {failed = true}}
        if failed {unregisterAll();bindings = old;registerAll();fail(L("默认快捷键被占用，已保留原设置。"));return false}
        bindings = Dictionary(uniqueKeysWithValues:CaptureAction.allCases.map {($0.rawValue,$0.defaultShortcut)});errors = [:];persist();isError = false;message = L("已恢复默认快捷键。");return true
    }
    func beginRecording(_ action:CaptureAction) {
        cancelRecording();recording = action;isError = false;message = L("请按下「{0}」的组合键；Esc 取消。" ,"\(action.title)")
        unregisterAll()
        monitor = NSEvent.addLocalMonitorForEvents(matching:.keyDown) { [weak self] event in
            guard let self,let action = self.recording else {return event}
            if event.keyCode == 53 {self.cancelRecording();return nil}
            if event.keyCode == 48 {self.cancelRecording();return event}
            let candidate = CaptureShortcut(event:event)
            if let error = candidate.validationError {self.fail(error);return nil}
            self.endRecording()
            self.update(action,to:candidate)
            return nil
        }
        resignObserver = NotificationCenter.default.addObserver(forName:NSApplication.didResignActiveNotification,object:nil,queue:.main) { [weak self] _ in Task { @MainActor in self?.cancelRecording() } }
    }
    private func endRecording() {
        guard recording != nil else {return}
        if let monitor {NSEvent.removeMonitor(monitor);self.monitor = nil}
        if let observer = resignObserver {NotificationCenter.default.removeObserver(observer);resignObserver = nil}
        recording = nil
        if active {registerAll()}
    }
    func cancelRecording() {guard recording != nil else {return};endRecording();isError = false;message = L("已取消，原快捷键保持不变。")}
    func clear(_ action:CaptureAction) {cancelRecording();update(action,to:nil)}
}
@MainActor final class SettingsController:NSObject,NSWindowDelegate {
    private var window:NSWindow?
    let shortcuts:ShortcutStore
    init(shortcuts:ShortcutStore) {self.shortcuts = shortcuts}
    func show() {
        if window == nil {
            let w = NSWindow(contentRect:NSRect(x:0,y:0,width:640,height:620),styleMask:[.titled,.closable],backing:.buffered,defer:false)
            w.title = L("轻截图设置");w.isReleasedWhenClosed = false;w.delegate = self
            w.contentView = NSHostingView(rootView:ShortcutSettingsView(store:shortcuts).preferredColorScheme(.light));w.center();window = w
        }
        NSApp.unhide(nil);NSApp.activate(ignoringOtherApps:true);window?.makeKeyAndOrderFront(nil)
    }
    func refreshLanguage() {window?.title = L("轻截图设置")}
    func windowWillClose(_ notification:Notification) {shortcuts.cancelRecording()}
    func windowDidResignKey(_ notification:Notification) {shortcuts.cancelRecording()}
}
struct ShortcutSettingsView:View {
    @ObservedObject var languageStore = LanguageStore.shared
    @ObservedObject var store:ShortcutStore
    var body:some View {
        VStack(alignment:.leading,spacing:20) {
            HStack(spacing:13) {
                Image(systemName:"keyboard").font(.system(size:25)).foregroundStyle(accent).frame(width:52,height:52).background(accent.opacity(0.1)).clipShape(RoundedRectangle(cornerRadius:13))
                VStack(alignment:.leading,spacing:5) {Text(L("截图快捷键")).font(.system(size:22,weight:.semibold));Text(L("随手一按，捕捉眼前的灵感。")).foregroundStyle(.secondary).font(.system(size:12))}
            }
            VStack(alignment:.leading,spacing:8) {
                Picker(L("语言"),selection:$languageStore.selection) {
                    ForEach(AppLanguage.allCases) {language in Text(language.title).tag(language)}
                }.pickerStyle(.menu).frame(maxWidth:340,alignment:.leading)
                Text(L("更改语言后立即生效。系统文件对话框跟随 macOS 的语言设置。")).font(.system(size:11)).foregroundStyle(.secondary)
            }
            VStack(spacing:0) {
                ForEach(CaptureAction.allCases) {action in
                    HStack(spacing:12) {
                        Image(systemName:action.icon).foregroundStyle(accent).frame(width:24)
                        VStack(alignment:.leading,spacing:4) {Text(action.title).font(.system(size:13,weight:.medium));if let error = store.errors[action.rawValue] {Text(error).font(.system(size:10)).foregroundStyle(.red)}}
                        Spacer()
                        Button {store.beginRecording(action)} label: {
                            Text(store.recording == action ? L("请按组合键…") : store.display(action)).font(.system(size:14,weight:.medium,design:.monospaced)).frame(width:146,height:30)
                        }.buttonStyle(.bordered).tint(store.recording == action ? accent : nil).accessibilityLabel(L("设置{0}快捷键" ,"\(action.title)")).accessibilityValue(store.display(action))
                        Button {store.clear(action)} label: {Image(systemName:"xmark.circle.fill").foregroundStyle(.secondary)}.buttonStyle(.plain).help(L("停用{0}快捷键" ,"\(action.title)")).accessibilityLabel(L("停用{0}快捷键" ,"\(action.title)")).disabled(store.shortcut(action) == nil)
                    }.padding(.horizontal,18).padding(.vertical,14)
                    if action != .full {Divider().padding(.leading,54)}
                }
            }.background(.white).clipShape(RoundedRectangle(cornerRadius:12)).overlay(RoundedRectangle(cornerRadius:12).stroke(.gray.opacity(0.12)))
            HStack(alignment:.top,spacing:8) {Image(systemName:store.isError ? "exclamationmark.circle" : store.recording == nil ? "checkmark.circle" : "keyboard");Text(store.message).fixedSize(horizontal:false,vertical:true)}.font(.system(size:12)).foregroundStyle(store.isError ? Color.red : accent).frame(minHeight:32,alignment:.topLeading)
            Text(L("使用 ⌘ Command 或 ⌃ Control 搭配其他按键。快捷键全局生效；关闭编辑器后仍可使用。按键名称按美式键盘物理位置显示。")).font(.system(size:11)).foregroundStyle(.secondary).lineSpacing(4)
            Divider()
            HStack {Button(L("恢复默认")) {store.restoreDefaults()};Spacer();if store.recording != nil {Button(L("取消录入")) {store.cancelRecording()}};Text(L("自动保存 · 即时生效")).font(.system(size:11)).foregroundStyle(.secondary)}
        }.padding(28).frame(width:640,height:620).background(Color(nsColor:NSColor(hex:0xF6F8F5))).tint(accent)
    }
}
