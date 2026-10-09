import AppKit
import SwiftUI
import Carbon
import Combine

@main struct QingShotMain {
    static func main() {
        let app = NSApplication.shared
        if CommandLine.arguments.contains("--shortcut-self-test") {ShortcutTests.run();return}
        if CommandLine.arguments.contains("--localization-self-test") {LocalizationTests.run();return}
        if CommandLine.arguments.contains("--self-test") {SelfTest.run();return}
        let delegate = AppDelegate(); app.delegate = delegate; app.setActivationPolicy(.regular); app.run()
        withExtendedLifetime(delegate) {}
    }
}
@MainActor final class AppDelegate:NSObject,NSApplicationDelegate {
    let model = ShotModel.shared
    var statusItem:NSStatusItem!
    let shortcuts = ShortcutStore.shared
    lazy var settingsController = SettingsController(shortcuts:shortcuts)
    var shortcutObserver:AnyCancellable?
    var handler:EventHandlerRef?
    var recordObserver:AnyCancellable?
    var languageObserver:AnyCancellable?
    func applicationDidFinishLaunching(_ notification:Notification) {
        let w = NSWindow(contentRect:NSRect(x:0,y:0,width:1180,height:790),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        w.title = L("轻截图 QingShot"); w.titlebarAppearsTransparent = true; w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView:ContentView(model:model).preferredColorScheme(.light)); w.minSize = CGSize(width:1040,height:730);w.center();model.window = w
        setupMenu(); setupStatus(); setupHotkeys();model.showWindow()
        languageObserver = LanguageStore.shared.$selection.dropFirst().receive(on:RunLoop.main).sink { [weak self] _ in
            guard let self else {return}
            self.setupMenu();self.setupStatus();self.settingsController.refreshLanguage();self.shortcuts.refreshLanguage()
            self.model.window?.title = L("轻截图 QingShot")
            if !self.model.busy && !self.model.recordStarting {self.model.status = self.model.recording ? L("正在录制主显示器（无音频）· 菜单栏可停止") : L("准备好，捕捉一个好想法。")}
        }
        if CommandLine.arguments.contains("--demo") {model.demo()}
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication) -> Bool {false}
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows:Bool) -> Bool {model.showWindow();return true}
    func applicationShouldTerminate(_ sender:NSApplication) -> NSApplication.TerminateReply {
        if model.recording || model.recordStarting {model.alert(L("请先停止录屏"),L("录屏文件完成保存后再退出轻截图。"));return .terminateCancel}
        model.captureProcess?.terminate();return .terminateNow
    }
    func item(_ title:String,_ action:Selector,_ key:String = "") -> NSMenuItem {let i = NSMenuItem(title:title,action:action,keyEquivalent:key);i.target = self;return i}
    func setupMenu() {
        let main = NSMenu()
        let appRoot = NSMenuItem();let app = NSMenu();appRoot.submenu = app;main.addItem(appRoot)
        app.addItem(item(L("关于轻截图"),#selector(about)));app.addItem(item(L("设置…"),#selector(settings),","));app.addItem(.separator());app.addItem(item(L("退出轻截图"),#selector(quit),"q"))
        let fileRoot = NSMenuItem(title:L("文件"),action:nil,keyEquivalent:"");let file = NSMenu(title:L("文件"));fileRoot.submenu = file;main.addItem(fileRoot)
        file.addItem(item(L("区域截图"),#selector(area),"n"));file.addItem(item(L("导入图片…"),#selector(openImage),"o"));file.addItem(item(L("导出 PNG…"),#selector(save),"s"));file.addItem(item(L("拼接长图…"),#selector(stitch)));file.addItem(.separator());file.addItem(item(L("关闭窗口"),#selector(closeWindow),"w"))
        let editRoot = NSMenuItem(title:L("编辑"),action:nil,keyEquivalent:"");let edit = NSMenu(title:L("编辑"));editRoot.submenu = edit;main.addItem(editRoot)
        edit.addItem(item(L("撤销标注 / 裁剪"),#selector(undo),"z"));let redo = item(L("重做"),#selector(redoAction),"z");redo.keyEquivalentModifierMask = [.command,.shift];edit.addItem(redo)
        edit.addItem(.separator());edit.addItem(item(L("复制图片"),#selector(copyImage),"c"));edit.addItem(item(L("粘贴图片"),#selector(paste),"v"));edit.addItem(NSMenuItem(title:L("全选"),action:#selector(NSText.selectAll(_:)),keyEquivalent:"a"))
        let windowRoot = NSMenuItem(title:L("窗口"),action:nil,keyEquivalent:"");let win = NSMenu(title:L("窗口"));windowRoot.submenu = win;main.addItem(windowRoot);win.addItem(item(L("显示编辑器"),#selector(show)));win.addItem(item(L("贴图置顶"),#selector(pin)));win.addItem(item(L("试用演示图"),#selector(demo)))
        NSApp.mainMenu = main
    }
    func setupStatus() {
        if statusItem == nil {statusItem = NSStatusBar.system.statusItem(withLength:NSStatusItem.squareLength)}
        statusItem.button?.image = NSImage(systemSymbolName:"viewfinder",accessibilityDescription:L("轻截图"))
        let menu = NSMenu();menu.addItem(item(L("区域截图     ⌃⇧2"),#selector(area)));menu.addItem(item(L("窗口截图     ⌃⇧3"),#selector(windowCapture)));menu.addItem(item(L("全屏截图     ⌃⇧4"),#selector(full)));menu.addItem(.separator());menu.addItem(item(L("显示编辑器"),#selector(show)));menu.addItem(item(L("设置…"),#selector(settings)));menu.addItem(item(L("开始录屏（主屏，无音频）"),#selector(record)));menu.addItem(item(L("停止录屏"),#selector(stopRecord)));menu.addItem(.separator());menu.addItem(item(L("退出轻截图"),#selector(quit)));statusItem.menu = menu
        shortcutObserver = shortcuts.$bindings.receive(on:RunLoop.main).sink { [weak self] bindings in
            guard let self else {return}
            for (index,action) in CaptureAction.allCases.enumerated() {
                menu.item(at:index)?.title = action.title + "     " + (bindings[action.rawValue]?.display ?? L("未设置"))
            }
            if !self.shortcuts.errors.isEmpty {self.model.status = L("部分快捷键被占用，请到设置中更换。")}
        }
        recordObserver = model.$recording.receive(on:RunLoop.main).sink { [weak self] active in
            self?.statusItem.button?.image = NSImage(systemSymbolName:active ? "record.circle.fill" : "viewfinder",accessibilityDescription:active ? L("正在录屏，点击菜单停止") : L("轻截图"))
            self?.statusItem.button?.contentTintColor = active ? .systemRed : nil
        }
    }
    func setupHotkeys() {
        var spec = EventTypeSpec(eventClass:OSType(kEventClassKeyboard),eventKind:UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(),{ _,event,context in
            guard let event,let context else {return noErr}
            var id = EventHotKeyID();GetEventParameter(event,EventParamName(kEventParamDirectObject),EventParamType(typeEventHotKeyID),nil,MemoryLayout<EventHotKeyID>.size,nil,&id)
            let delegate = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in guard delegate.shortcuts.recording == nil,let action = CaptureAction.allCases.first(where: {$0.hotkeyID == id.id}) else {return}; delegate.model.capture(action.rawValue) };return noErr
        },1,&spec,Unmanaged.passUnretained(self).toOpaque(),&handler)
        shortcuts.activate()
        if !shortcuts.errors.isEmpty {model.status = L("部分快捷键被占用，请到设置中更换。")}
    }
    @objc func settings() {settingsController.show()}

    @objc func about() {model.alert(L("轻截图 QingShot") + " 0.2.0",L("原生 macOS 截图工具\n截图 · 标注 · 文字识别 · 美化 · 拼接 · 录屏\n截图与识别均在本机处理。\nApple Development 签名开发预览版，未进行 Developer ID 公证。"))}
    @objc func quit() {NSApp.terminate(nil)}
    @objc func area() {model.capture("area")}
    @objc func windowCapture() {model.capture("window")}
    @objc func full() {model.capture("full")}
    @objc func show() {model.showWindow()}
    @objc func openImage() {model.openImage()}
    @objc func save() {model.save()}
    @objc func copyImage() {if let text = NSApp.keyWindow?.firstResponder as? NSTextView {text.copy(nil)} else {model.copy()}}
    @objc func paste() {if let text = NSApp.keyWindow?.firstResponder as? NSTextView {text.paste(nil)} else {model.paste()}}
    @objc func undo() {model.undo()}
    @objc func redoAction() {model.redo()}
    @objc func stitch() {model.stitch()}
    @objc func pin() {model.pin()}
    @objc func demo() {model.demo()}
    @objc func record() {model.startRecording()}
    @objc func stopRecord() {model.stopRecording()}
    @objc func closeWindow() {NSApp.keyWindow?.performClose(nil)}
}
