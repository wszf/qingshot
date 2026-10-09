import AppKit
import SwiftUI
import Vision
import ScreenCaptureKit
import UniformTypeIdentifiers

struct HistoryItem: Identifiable { let id: URL; let image: NSImage; let date: Date }
struct EditState { let image: NSImage; let marks: [Mark] }
@MainActor final class ShotModel: ObservableObject {
    static let shared = ShotModel()
    @Published var image: NSImage?
    @Published var marks: [Mark] = []
    @Published var tool: MarkTool = .arrow
    @Published var color: Color = Color(nsColor:NSColor(hex:0xF26C4F))
    @Published var lineWidth: Double = 5
    @Published var backdrop: Backdrop = .none
    @Published var padding: Double = 64
    @Published var history: [HistoryItem] = []
    @Published var status = L("准备好，捕捉一个好想法。")
    @Published var busy = false
    @Published var recording = false
    @Published var recordStarting = false
    @Published var showOCR = false
    @Published var ocrText = ""
    @Published var name = L("未命名截图")
    @Published var revision = 0
    var undoStack: [EditState] = [], redoStack: [EditState] = []
    var window: NSWindow?
    var quickPanel: NSPanel?
    var pins: [NSWindow] = []
    var didRequestScreenAccess = false
    var captureProcess: Process?
    var recorder: ScreenRecorder?
    var historyURL: URL {
        FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("QingShot/History",isDirectory:true)
    }
    init() { loadHistory() }
    func loadHistory() {
        do {
            try FileManager.default.createDirectory(at:historyURL,withIntermediateDirectories:true)
            let urls = try FileManager.default.contentsOfDirectory(at:historyURL,includingPropertiesForKeys:[.creationDateKey]).filter {$0.pathExtension == "png"}.sorted {$0.lastPathComponent > $1.lastPathComponent}
            history = urls.prefix(30).compactMap { url in guard let img = NSImage(contentsOf:url) else {return nil}; return HistoryItem(id:url,image:img,date:(try? url.resourceValues(forKeys:[.creationDateKey]).creationDate) ?? Date()) }
        } catch { status = L("无法读取历史记录：{0}" ,"\(error.localizedDescription)") }
    }
    func remember(_ img:NSImage) {
        let stamp = ISO8601DateFormatter().string(from:Date()).replacingOccurrences(of:":",with:"-")
        let url = historyURL.appendingPathComponent("\(stamp)-\(UUID().uuidString.prefix(6)).png")
        do {
            guard let data = img.png else { throw CocoaError(.fileWriteUnknown) }; try data.write(to:url,options:.atomic)
            let urls = try FileManager.default.contentsOfDirectory(at:historyURL,includingPropertiesForKeys:nil).filter {$0.pathExtension == "png"}.sorted {$0.lastPathComponent > $1.lastPathComponent}
            for old in urls.dropFirst(30) { try FileManager.default.removeItem(at:old) }
            loadHistory()
        } catch { status = L("图片已打开，但保存历史失败：{0}" ,"\(error.localizedDescription)") }
    }
    func load(_ img:NSImage, name:String, save:Bool = true) {
        image = img; marks = []; undoStack = []; redoStack = []; backdrop = .none; self.name = name; revision += 1
        status = L("拖动进行标注 · ⌘Z 撤销 · ⌘C 复制 · ⌘S 保存")
        if save { remember(img) }
    }
    func demo() { load(Renderer.demo(),name:L("欢迎使用轻截图"),save:false) }
    func checkpoint() { guard let image else {return}; undoStack.append(EditState(image:image,marks:marks)); if undoStack.count > 40 {undoStack.removeFirst()}; redoStack = []; revision += 1 }
    func add(_ mark:Mark) { checkpoint(); marks.append(mark) }
    func undo() { guard let state = undoStack.popLast(), let image else {return}; redoStack.append(EditState(image:image,marks:marks)); self.image = state.image; marks = state.marks; revision += 1 }
    func redo() { guard let state = redoStack.popLast(), let image else {return}; undoStack.append(EditState(image:image,marks:marks)); self.image = state.image; marks = state.marks; revision += 1 }
    func crop(_ rect:CGRect) { guard let image,rect.width >= 4,rect.height >= 4 else {return}; checkpoint(); self.image = Renderer.crop(Renderer.render(image,marks:marks),rect:rect); marks = []; status = L("已裁剪 · ⌘Z 可撤销") }
    func output() -> NSImage? { guard let image else {return nil}; return Renderer.render(image,marks:marks,backdrop:backdrop,padding:padding) }
    func copy() { guard let img = output(), let data = img.png else {return}; NSPasteboard.general.clearContents(); NSPasteboard.general.setData(data,forType:.png); status = L("已复制图片，可粘贴到其他应用") }
    func save() {
        guard let img = output(),let data = img.png else {return}
        let panel = NSSavePanel(); panel.allowedContentTypes = [.png]; panel.nameFieldStringValue = "QingShot-\(Int(Date().timeIntervalSince1970)).png"
        if panel.runModal() == .OK, let url = panel.url { do {try data.write(to:url,options:.atomic); status = L("已保存到 {0}" ,"\(url.lastPathComponent)")} catch {alert(L("保存失败"),error.localizedDescription)} }
    }
    func openImage() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.png,.jpeg,.tiff,.heic]; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK,let url = panel.url,let img = NSImage(contentsOf:url) { load(img,name:url.deletingPathExtension().lastPathComponent) }
    }
    func paste() { guard let img = NSImage(pasteboard:NSPasteboard.general) else {status = L("剪贴板中没有图片");return}; load(img,name:L("剪贴板图片")) }
    func showWindow() { NSApp.unhide(nil); NSApp.activate(ignoringOtherApps:true); window?.makeKeyAndOrderFront(nil) }
    func capture(_ mode:String) {
        guard !busy, !recording, !recordStarting else {return}
        guard ensureScreenCaptureAccess() else {return}
        busy = true; quickPanel?.orderOut(nil); let wasVisible = window?.isVisible ?? false
        window?.orderOut(nil); pins.forEach {$0.orderOut(nil)}; NSApp.hide(nil)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("qingshot-\(UUID().uuidString).png")
        DispatchQueue.main.asyncAfter(deadline:.now()+0.35) { [self] in
            let process = Process(); process.executableURL = URL(fileURLWithPath:"/usr/sbin/screencapture")
            process.arguments = ["-x","-t","png"] + (mode == "full" ? ["-m"] : mode == "window" ? ["-i","-w"] : ["-i"]) + [url.path]
            let err = Pipe(); process.standardError = err
            process.terminationHandler = { [weak self] p in
                Task { @MainActor in
                    guard let self else {return}; self.busy = false; self.captureProcess = nil
                    defer {try? FileManager.default.removeItem(at:url)}
                    self.pins.forEach {$0.orderFrontRegardless()}
                    if let img = NSImage(contentsOf:url) {
                        self.load(img,name:mode == "window" ? L("窗口截图") : mode == "full" ? L("全屏截图") : L("区域截图")); self.showQuickPanel()
                    } else {
                        self.status = p.terminationStatus == 0 || p.terminationStatus == 1 ? L("截图已取消；若未出现选区，请检查屏幕录制权限") : L("截图失败，请检查屏幕录制权限")
                        if wasVisible {self.showWindow()}
                    }
                }
            }
            do { try process.run(); captureProcess = process } catch {busy = false; showWindow(); alert(L("无法截图"),error.localizedDescription)}
        }
    }
    func showQuickPanel() {
        quickPanel?.close()
        let panel = NSPanel(contentRect:NSRect(x:0,y:0,width:300,height:244),styleMask:[.nonactivatingPanel,.borderless],backing:.buffered,defer:false)
        panel.isReleasedWhenClosed = false; panel.level = .floating; panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView:QuickView(model:self))
        let frame = (NSScreen.screens.first {$0.frame.contains(NSEvent.mouseLocation)} ?? NSScreen.main)?.visibleFrame ?? .zero
        panel.setFrameOrigin(CGPoint(x:frame.maxX-320,y:frame.minY+22)); panel.orderFrontRegardless(); quickPanel = panel
    }
    func pin() {
        guard let img = output() else {return}
        let s = img.pixelSize, factor = min(1,480/s.width,600/s.height)
        let panel = NSPanel(contentRect:NSRect(x:0,y:0,width:s.width*factor,height:s.height*factor),styleMask:[.titled,.closable,.resizable,.utilityWindow],backing:.buffered,defer:false)
        panel.title = L("置顶参考 · 关闭窗口即可取消"); panel.isReleasedWhenClosed = false; panel.level = .floating; panel.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary]
        let view = NSImageView(); view.image = img; view.imageScaling = .scaleProportionallyUpOrDown; panel.contentView = view; panel.center(); panel.orderFrontRegardless(); pins.removeAll {!$0.isVisible}; pins.append(panel); status = L("图片已置顶，可拖动或缩放")
    }
    func recognize() {
        guard let img = image, !busy, let cg = Renderer.render(img,marks:marks).cgImage(forProposedRect:nil,context:nil,hints:nil) else {return}
        busy = true; status = L("正在本机识别文字…")
        DispatchQueue.global(qos:.userInitiated).async {
            let req = VNRecognizeTextRequest(); req.recognitionLevel = .accurate; req.recognitionLanguages = ["zh-Hans","en-US"]; req.usesLanguageCorrection = true
            do {
                try VNImageRequestHandler(cgImage:cg,options:[:]).perform([req])
                let text = (req.results ?? []).compactMap {$0.topCandidates(1).first?.string}.joined(separator:"\n")
                Task { @MainActor in self.busy = false; self.ocrText = text; self.showOCR = true; self.status = text.isEmpty ? L("没有识别到文字") : L("文字识别完成，可编辑后复制") }
            } catch { Task { @MainActor in self.busy = false; self.alert(L("文字识别失败"),error.localizedDescription) } }
        }
    }
    func stitch() {
        let p = NSOpenPanel(); p.allowedContentTypes = [.png,.jpeg]; p.allowsMultipleSelection = true; p.message = L("选择至少两张图片，按文件名升序从上到下拼接。")
        guard p.runModal() == .OK,p.urls.count >= 2 else {return}
        let urls = p.urls.sorted {$0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending}
        let alert = NSAlert(); alert.messageText = L("拼接长图"); alert.informativeText = L("顺序：\n") + urls.map(\.lastPathComponent).joined(separator:" → ") + L("\n\n输入相邻图片的重叠像素（统一宽度后计算）。0 表示直接拼接。")
        let field = NSTextField(string:"0"); field.frame = NSRect(x:0,y:0,width:260,height:28); alert.accessoryView = field; alert.addButton(withTitle:L("拼接")); alert.addButton(withTitle:L("取消"))
        guard alert.runModal() == .alertFirstButtonReturn else {return}
        guard let overlap = Double(field.stringValue),overlap >= 0 else {self.alert(L("重叠值无效"),L("请输入大于等于 0 的数字。"));return}
        let images = urls.compactMap {NSImage(contentsOf:$0)}
        guard images.count == urls.count,let result = Renderer.stitch(images,overlap:overlap) else {self.alert(L("无法拼接"),L("图片无法读取，或结果超过 1 亿像素 / 32000 像素高度。请减少图片数量。"));return}
        load(result,name:L("拼接长图")); status = L("已按文件名顺序拼接 {0} 张图片" ,"\(images.count)")
    }
    func deleteHistory(_ item:HistoryItem) { do {try FileManager.default.removeItem(at:item.id); loadHistory()} catch {alert(L("删除失败"),error.localizedDescription)} }
    func startRecording() {
        guard !recording,!busy,!recordStarting else {return}
        guard ensureScreenCaptureAccess() else {return}
        let p = NSSavePanel(); p.allowedContentTypes = [.mpeg4Movie]; p.nameFieldStringValue = "QingShot-\(Int(Date().timeIntervalSince1970)).mp4"
        guard p.runModal() == .OK,let url = p.url else {return}
        recordStarting = true; status = L("正在准备录制主显示器…")
        let r = ScreenRecorder(); recorder = r
        r.finished = { [weak self] error in
            guard let self else {return}; self.recording = false; self.recordStarting = false; self.recorder = nil
            self.showWindow()
            if let error {self.alert(L("录屏失败"),error.localizedDescription)} else {self.status = L("录屏已保存：{0}" ,"\(url.lastPathComponent)"); NSWorkspace.shared.activateFileViewerSelecting([url])}
        }
        Task {
            do { try await r.start(url:url); recording = true; recordStarting = false; status = L("正在录制主显示器（无音频）· 菜单栏可停止"); window?.orderOut(nil) }
            catch {recordStarting = false; recorder = nil; alert(L("无法开始录屏"),error.localizedDescription)}
        }
    }
    func stopRecording() { guard recording else {return}; recording = false; recordStarting = true; status = L("正在完成录屏文件…"); Task { do { try await recorder?.stop() } catch {recordStarting = false; alert(L("停止录屏失败"),error.localizedDescription)} } }
    func ensureScreenCaptureAccess() -> Bool {
        if CGPreflightScreenCaptureAccess() {return true}
        // Request once per process; the request itself can grant access immediately.
        if !didRequestScreenAccess {
            didRequestScreenAccess = true
            if CGRequestScreenCaptureAccess() || CGPreflightScreenCaptureAccess() {return true}
        }
        showScreenCapturePermissionAlert()
        return false
    }
    func showScreenCapturePermissionAlert() {
        let a = NSAlert()
        a.messageText = L("需要屏幕录制权限")
        a.informativeText = L("点击「打开系统设置」，在「录屏与系统录音」中允许 QingShot，然后完全退出并重新打开应用。\n\n如果开关已经开启仍提示未授权，可能是旧开发版本的签名记录：请在设置中移除旧 QingShot 条目，再通过 + 添加当前应用并开启权限。\n\n当前应用：{0}" ,"\(Bundle.main.bundleURL.path)")
        a.addButton(withTitle:L("打开系统设置"))
        a.addButton(withTitle:L("稍后"))
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let url = URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        if !NSWorkspace.shared.open(url) {
            alert(L("无法打开系统设置"),L("请手动打开系统设置 → 隐私与安全性 → 屏幕与系统音频录制，允许 QingShot。"))
        }
    }
    func alert(_ title:String,_ message:String) { let a = NSAlert(); a.messageText = title; a.informativeText = message; a.runModal() }
}
@MainActor final class ScreenRecorder: NSObject, SCRecordingOutputDelegate, SCStreamDelegate {
    var stream: SCStream?
    var finished: ((Error?) -> Void)?
    var completed = false
    func start(url:URL) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false,onScreenWindowsOnly:true)
        guard let display = content.displays.first(where: {$0.displayID == CGMainDisplayID()}) ?? content.displays.first else {throw CocoaError(.featureUnsupported)}
        let excluded = content.applications.filter {$0.processID == ProcessInfo.processInfo.processIdentifier}
        let filter = SCContentFilter(display:display,excludingApplications:excluded,exceptingWindows:[])
        let config = SCStreamConfiguration(); config.width = display.width/2*2; config.height = display.height/2*2; config.minimumFrameInterval = CMTime(value:1,timescale:30); config.showsCursor = true; config.capturesAudio = false
        let outputConfig = SCRecordingOutputConfiguration(); outputConfig.outputURL = url; outputConfig.outputFileType = .mp4; outputConfig.videoCodecType = .h264
        let output = SCRecordingOutput(configuration:outputConfig,delegate:self)
        let s = SCStream(filter:filter,configuration:config,delegate:self); stream = s
        try s.addRecordingOutput(output); try await s.startCapture()
    }
    func stop() async throws {try await stream?.stopCapture()}
    func finish(_ error:Error?) {guard !completed else {return}; completed = true; finished?(error)}
    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput:SCRecordingOutput) {Task { @MainActor in self.finish(nil) }}
    nonisolated func recordingOutput(_ recordingOutput:SCRecordingOutput,didFailWithError error:Error) {Task { @MainActor in self.finish(error) }}
    nonisolated func stream(_ stream:SCStream,didStopWithError error:Error) {Task { @MainActor in self.finish(error) }}
}
