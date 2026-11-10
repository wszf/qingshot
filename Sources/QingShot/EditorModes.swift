import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum PostCaptureMode:String, CaseIterable, Identifiable {
    case editor, inline
    var id:String {rawValue}
    var title:String {switch self {case .editor: return L("居中小编辑器"); case .inline: return L("在选区上直接标注")}}
    static let defaultsKey = "postCaptureMode.v1"
    static func stored(in defaults:UserDefaults = .standard) -> PostCaptureMode {
        PostCaptureMode(rawValue:defaults.string(forKey:defaultsKey) ?? "") ?? .editor
    }
    static func save(_ mode:PostCaptureMode, in defaults:UserDefaults = .standard) {defaults.set(mode.rawValue,forKey:defaultsKey)}
}

enum PanelOCRState:Equatable {
    case idle, running, result, empty
    case error(String)
}

enum CaptureKeyAction:Equatable {case cancel, copy, save, undo, redo, tool(Int)}
enum CaptureKeyRouter {
    static func isTextInput(_ window:NSWindow?) -> Bool {
        guard let responder = window?.firstResponder else {return false}
        return responder is NSText || responder is NSTextField
    }
    static func action(_ event:NSEvent) -> CaptureKeyAction? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 53 {return .cancel}
        if event.keyCode == 36 || event.keyCode == 76 {return .copy}
        if flags.contains(.command),let key = event.charactersIgnoringModifiers?.lowercased() {
            switch key {
            case "z": return flags.contains(.shift) ? .redo : .undo
            case "c": return .copy
            case "s": return .save
            default: break
            }
        }
        if flags.isEmpty,let index = toolIndex(event.keyCode) {return .tool(index)}
        return nil
    }
    static func toolIndex(_ keyCode:UInt16) -> Int? {
        [18:1,19:2,20:3,21:4,23:5,22:6,26:7,28:8,25:9][keyCode]
    }
}

enum PostCaptureLayout {
    static let horizontalChrome:CGFloat = 32
    static let verticalChrome:CGFloat = 146
    static let minWidth:CGFloat = 700
    static let minHeight:CGFloat = 260
    static let maxFraction:CGFloat = 0.7

    static func nativeSize(_ image:CGSize, pixelScale:CGFloat) -> CGSize {
        let scale = max(1,pixelScale)
        return CGSize(width:image.width/scale,height:image.height/scale)
    }
    static func canvasScale(image:CGSize, pixelScale:CGFloat, available:CGSize) -> CGFloat {
        let native = nativeSize(image,pixelScale:pixelScale)
        guard native.width >= 1,native.height >= 1 else {return 1}
        return min(1,max(0,available.width/native.width),max(0,available.height/native.height))
    }
    static func panelSize(image:CGSize, pixelScale:CGFloat, screen:NSRect, maxFraction:CGFloat = maxFraction) -> CGSize {
        let maxSize = CGSize(width:screen.width*maxFraction,height:screen.height*maxFraction)
        let available = CGSize(width:max(120,maxSize.width-horizontalChrome),height:max(100,maxSize.height-verticalChrome))
        let native = nativeSize(image,pixelScale:pixelScale)
        let scale = canvasScale(image:image,pixelScale:pixelScale,available:available)
        let canvas = CGSize(width:native.width*scale,height:native.height*scale)
        return CGSize(width:min(maxSize.width,max(minWidth,canvas.width+horizontalChrome)),
                      height:min(maxSize.height,max(minHeight,canvas.height+verticalChrome)))
    }
    static func centeredOrigin(size:CGSize, in screen:NSRect) -> NSPoint {
        let x = min(max(screen.minX,screen.midX-size.width/2),screen.maxX-size.width)
        let y = min(max(screen.minY,screen.midY-size.height/2),screen.maxY-size.height)
        return NSPoint(x:x,y:y)
    }
}

enum InlineToolbarLayout {
    static func frame(selection:NSRect, size:CGSize, screen:NSRect, gap:CGFloat = 10, margin:CGFloat = 8) -> NSRect {
        let width = min(size.width,max(1,screen.width-margin*2))
        let height = min(size.height,max(1,screen.height-margin*2))
        let x = min(max(selection.midX-width/2,screen.minX+margin),max(screen.minX+margin,screen.maxX-margin-width))
        let below = selection.minY-gap-height
        if below >= screen.minY+margin {return NSRect(x:x,y:below,width:width,height:height)}
        let above = selection.maxY+gap+26
        if above+height <= screen.maxY-margin {return NSRect(x:x,y:above,width:width,height:height)}
        let y = min(max(selection.minY+margin,screen.minY+margin),max(screen.minY+margin,screen.maxY-margin-height))
        return NSRect(x:x,y:y,width:width,height:height)
    }
}

final class PostCapturePanel:NSPanel {
    var onCancel:(()->Void)?
    override var canBecomeKey:Bool {true}
    override var canBecomeMain:Bool {true}
    override func keyDown(with event:NSEvent) {
        if event.keyCode == 53 {onCancel?()} else {super.keyDown(with:event)}
    }
    override func cancelOperation(_ sender:Any?) {onCancel?()}
}

@MainActor final class PostCaptureController:ObservableObject {
    private unowned let model:ShotModel
    private var panel:PostCapturePanel?
    private var monitor:Any?
    @Published private(set) var ocrState:PanelOCRState = .idle
    @Published private(set) var ocrNotice:String?
    private var ocrRequest = 0

    init(model:ShotModel) {self.model = model}

    func show() {
        close()
        guard let image = model.image,let screen = NSScreen.screens.first(where: {$0.frame.contains(NSEvent.mouseLocation)}) ?? NSScreen.main else {return}
        let size = PostCaptureLayout.panelSize(image:image.pixelSize,pixelScale:screen.backingScaleFactor,screen:screen.visibleFrame)
        let panel = PostCapturePanel(contentRect:NSRect(origin:.zero,size:size),styleMask:[.borderless],backing:.buffered,defer:false)
        panel.isReleasedWhenClosed = false;panel.isOpaque = false;panel.backgroundColor = .clear;panel.hasShadow = true
        panel.onCancel = { [weak self] in self?.handleEscape() }
        panel.level = .floating;panel.hidesOnDeactivate = false;panel.isFloatingPanel = true
        panel.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary]
        let host = NSHostingView(rootView:PostCaptureEditorView(model:model, controller:self, close:{ [weak self] in self?.close() }, copyAndClose:{ [weak self] in self?.copyAndClose() }, openMain:{ [weak self] in self?.openMain() }))
        panel.contentView = host
        panel.setFrame(NSRect(origin:PostCaptureLayout.centeredOrigin(size:size,in:screen.visibleFrame),size:size),display:false)
        self.panel = panel
        model.quickPanel = panel
        NSApp.unhide(nil);NSApp.activate(ignoringOtherApps:true);panel.makeKeyAndOrderFront(nil)
        monitor = NSEvent.addLocalMonitorForEvents(matching:.keyDown) { [weak self] event in
            guard let self,let panel = self.panel,panel.isVisible,event.window === panel else {return event}
            if event.keyCode == 53 {self.handleEscape();return nil}
            if self.ocrState != .idle {return event}
            guard CaptureKeyRouter.isTextInput(panel) == false,let action = CaptureKeyRouter.action(event) else {return event}
            switch action {
            case .cancel: self.handleEscape()
            case .copy: self.copyAndClose()
            case .save: self.model.save()
            case .undo: self.model.undo()
            case .redo: self.model.redo()
            case .tool(let n): if MarkTool.allCases.indices.contains(n-1) {self.model.tool = MarkTool.allCases[n-1]}
            }
            return nil
        }
    }

    func handleEscape() {
        if ocrState != .idle {dismissOCR()} else {close()}
    }

    func extractText() {
        guard model.image != nil, !model.busy, ocrState != .running else {return}
        ocrRequest += 1
        let request = ocrRequest
        ocrState = .running;ocrNotice = nil
        model.recognize(showSheet:false) { [weak self] text,error in
            guard let self,self.ocrRequest == request else {return}
            if let error {
                self.ocrState = .error(error.localizedDescription)
                return
            }
            if text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
                self.ocrState = .empty
                return
            }
            self.ocrState = .result
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text,forType:.string)
            self.ocrNotice = L("已自动复制识别文字")
            self.model.status = L("已复制识别文字")
        }
    }

    func dismissOCR() {
        ocrRequest += 1
        ocrState = .idle;ocrNotice = nil
    }

    func copyOCR() {
        guard !model.ocrText.isEmpty else {return}
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.ocrText,forType:.string)
        ocrNotice = L("已复制识别文字")
        model.status = L("已复制识别文字")
    }

    func close() {
        ocrRequest += 1;ocrState = .idle;ocrNotice = nil
        if let monitor {NSEvent.removeMonitor(monitor);self.monitor = nil}
        panel?.orderOut(nil);panel = nil
        if model.quickPanel?.isVisible == false {model.quickPanel = nil}
    }
    func copyAndClose() {model.copy();model.status = L("已复制图片，可粘贴到其他应用");close()}
    func openMain() {close();model.showWindow()}
}

struct PostCaptureEditorView: View {
    @ObservedObject var languageStore = LanguageStore.shared
    @ObservedObject var model:ShotModel
    @ObservedObject var controller:PostCaptureController
    let close:()->Void
    let copyAndClose:()->Void
    let openMain:()->Void
    @FocusState private var ocrFocused:Bool

    var body: some View {
        VStack(spacing:0) {
            topBar.frame(height:54)
            Divider()
            ZStack {
                CanvasBridge(model:model, inset:0, maxScale:1).padding(16)
                if controller.ocrState != .idle {ocrOverlay.padding(16)}
            }.frame(maxWidth:.infinity,maxHeight:.infinity)
            Divider()
            bottomBar.frame(height:58)
        }
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius:14))
        .overlay(RoundedRectangle(cornerRadius:14).stroke(Theme.stroke))
        .tint(accent)
        .onChange(of:controller.ocrState) {_,state in
            if case .result = state {ocrFocused = true} else {ocrFocused = false}
        }
    }

    var topBar: some View {
        HStack(spacing:8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing:0) {
                    HStack(spacing:2) {
                        ForEach(MarkTool.allCases) {tool in
                            Button {model.tool = tool} label: {
                                Image(systemName:tool.icon).font(.system(size:14,weight:.medium)).frame(width:30,height:30)
                                    .foregroundStyle(model.tool == tool ? accent : Color.secondary)
                                    .background(model.tool == tool ? accent.opacity(0.13) : .clear).clipShape(RoundedRectangle(cornerRadius:7))
                            }.buttonStyle(.plain).help(tool.label)
                        }
                    }.fixedSize()
                    Divider().frame(height:24).padding(.horizontal,12)
                    HStack(spacing:0) {
                        ColorPicker(L("颜色"),selection:$model.color,supportsOpacity:false).labelsHidden().frame(width:30,height:30).fixedSize()
                        Divider().frame(height:20).padding(.horizontal,12)
                        lineWidthMenu
                    }
                    .padding(.horizontal,6).padding(.vertical,2)
                    .background(Theme.chip).clipShape(Capsule())
                    .fixedSize()
                    Divider().frame(height:24).padding(.horizontal,12)
                    HStack(spacing:4) {
                        Button {model.undo()} label: {Image(systemName:"arrow.uturn.backward")}.buttonStyle(.plain).disabled(model.undoStack.isEmpty).help(L("撤销 ⌘Z"))
                        Button {model.redo()} label: {Image(systemName:"arrow.uturn.forward")}.buttonStyle(.plain).disabled(model.redoStack.isEmpty).help(L("重做 ⇧⌘Z"))
                    }.fixedSize()
                }.fixedSize()
            }
            Button(action:close) {Image(systemName:"xmark").font(.system(size:13,weight:.semibold)).foregroundStyle(.secondary).frame(width:28,height:28)}.buttonStyle(.plain).help(L("关闭"))
        }.padding(.horizontal,14)
    }

    var lineWidthMenu: some View {
        Menu {
            Button {model.lineWidth = 3} label: {Text(L("细"))}
            Button {model.lineWidth = 5} label: {Text(L("中"))}
            Button {model.lineWidth = 9} label: {Text(L("粗"))}
        } label: {
            Image(systemName:"line.3.horizontal").font(.system(size:14,weight:.medium)).foregroundStyle(.secondary)
                .frame(width:30,height:30)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help(L("线宽") + " · " + (model.lineWidth >= 9 ? L("粗") : model.lineWidth >= 5 ? L("中") : L("细")))
    }

    var ocrOverlay: some View {
        VStack(alignment:.leading,spacing:10) {
            HStack(spacing:10) {
                Label(L("提取文字"),systemImage:"text.viewfinder").font(.system(size:14,weight:.semibold))
                Spacer()
                if case .result = controller.ocrState {
                    Button(L("复制全部")) {controller.copyOCR()}.buttonStyle(.borderedProminent)
                }
                Button {controller.dismissOCR()} label: {Image(systemName:"xmark").frame(width:24,height:24)}.buttonStyle(.plain).help(L("返回"))
            }
            switch controller.ocrState {
            case .running:
                VStack(spacing:10) {
                    ProgressView().controlSize(.large)
                    Text(L("正在本机识别文字…")).font(.system(size:12)).foregroundStyle(.secondary)
                }.frame(maxWidth:.infinity,maxHeight:.infinity)
            case .result:
                TextEditor(text:$model.ocrText).font(.system(size:14)).padding(8)
                    .background(Color(nsColor:.textBackgroundColor)).clipShape(RoundedRectangle(cornerRadius:8))
                    .focused($ocrFocused).onAppear {ocrFocused = true}
                if let notice = controller.ocrNotice {
                    Text(notice).font(.system(size:11)).foregroundStyle(accent)
                }
            case .empty:
                VStack(spacing:10) {
                    Image(systemName:"text.magnifyingglass").font(.system(size:24)).foregroundStyle(.secondary)
                    Text(L("没有识别到文字")).font(.system(size:13)).foregroundStyle(.secondary)
                }.frame(maxWidth:.infinity,maxHeight:.infinity)
            case .error(let message):
                VStack(spacing:8) {
                    Image(systemName:"exclamationmark.triangle").font(.system(size:24)).foregroundStyle(.orange)
                    Text(L("文字识别失败")).font(.system(size:13,weight:.medium))
                    Text(message).font(.system(size:11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.frame(maxWidth:.infinity,maxHeight:.infinity)
            case .idle:
                EmptyView()
            }
        }
        .padding(16)
        .background(Theme.overlay.opacity(0.98))
        .clipShape(RoundedRectangle(cornerRadius:12))
        .overlay(RoundedRectangle(cornerRadius:12).stroke(Theme.stroke))
        .shadow(color:Theme.shadow,radius:14,y:6)
    }

    var bottomBar: some View {
        HStack(spacing:8) {
            backgrounds.fixedSize()
            Divider().frame(height:20)
            Spacer(minLength:6)
            HStack(spacing:8) {
                ImageDragChip(model:model)
                Button(L("提取文字")) {controller.extractText()}.fixedSize()
                Button(L("置顶")) {model.pin()}.fixedSize()
                Button(L("保存")) {model.save()}.fixedSize()
                Button(L("主窗口")) {openMain()}.fixedSize()
                Button(action:copyAndClose) {Label(L("复制"),systemImage:"doc.on.doc")}.buttonStyle(.borderedProminent).fixedSize()
            }
        }.controlSize(.small).padding(.horizontal,14)
    }

    var backgrounds: some View {
        HStack(spacing:9) {
            Text(L("背景")).font(.system(size:11)).foregroundStyle(.secondary)
            ForEach(Backdrop.allCases) {background in
                backgroundsButton(background)
            }
            if model.backdrop != .none {
                Text(L("留白")).font(.system(size:11)).foregroundStyle(.secondary).padding(.leading,4)
                Slider(value:$model.padding,in:24...160,step:8).frame(width:78)
            }
        }
    }

    func backgroundsButton(_ background:Backdrop) -> some View {
        let selected = background == model.backdrop
        let fill = background == .none ? Theme.card : Color(nsColor:background.colors[1])
        return Button {model.backdrop = background} label: {
            Circle().fill(fill).frame(width:18,height:18).overlay(Circle().stroke(selected ? accent : Color.gray.opacity(0.3),lineWidth:selected ? 2 : 1))
        }.buttonStyle(.plain).help(background.label)
    }
}

struct ImageDragChip: View {
    @ObservedObject var model:ShotModel
    var body: some View {
        Image(systemName:"square.and.arrow.up.on.square").font(.system(size:12)).frame(width:32,height:26)
            .background(Theme.chip).clipShape(RoundedRectangle(cornerRadius:5))
            .help(L("拖到其他应用"))
            .onDrag {
                guard let data = model.output()?.png else {return NSItemProvider()}
                return NSItemProvider(item:data as NSData,typeIdentifier:UTType.png.identifier)
            }
    }
}

final class InlineToolbarPanel:NSPanel {
    override var canBecomeKey:Bool {true}
}

struct InlineToolbarView:View {
    @ObservedObject var languageStore = LanguageStore.shared
    @ObservedObject var model:ShotModel
    let onCancel:()->Void
    let onCopy:()->Void
    let onSave:()->Void
    let onPin:()->Void
    let onOCR:()->Void
    let onMain:()->Void

    var body:some View {
        GeometryReader { geometry in
            if geometry.size.width >= 800 {
                singleRow
            } else {
                twoRows
            }
        }
        .background(Theme.toolbar).clipShape(RoundedRectangle(cornerRadius:12))
        .overlay(RoundedRectangle(cornerRadius:12).stroke(Theme.stroke))
        .tint(accent)
    }

    var toolGroup:some View {
        HStack(spacing:2) {
            ForEach(MarkTool.allCases) {tool in
                Button {model.tool = tool} label: {
                    Image(systemName:tool.icon).font(.system(size:13,weight:.medium)).frame(width:27,height:28)
                        .foregroundStyle(model.tool == tool ? accent : Color.secondary)
                        .background(model.tool == tool ? accent.opacity(0.13) : .clear).clipShape(RoundedRectangle(cornerRadius:6))
                }.buttonStyle(.plain).help(tool.label)
            }
        }.fixedSize()
    }

    var colorWidthGroup:some View {
        HStack(spacing:0) {
            ColorPicker(L("颜色"),selection:$model.color,supportsOpacity:false).labelsHidden().frame(width:26,height:28).fixedSize()
            Divider().frame(height:20).padding(.horizontal,12)
            Picker(L("线宽"),selection:$model.lineWidth) {Text(L("细")).tag(3.0);Text(L("中")).tag(5.0);Text(L("粗")).tag(9.0)}.labelsHidden().pickerStyle(.segmented).frame(width:112).fixedSize()
        }
        .padding(.horizontal,6).padding(.vertical,2)
        .background(Theme.chip).clipShape(Capsule())
        .fixedSize()
    }

    var undoGroup:some View {
        HStack(spacing:3) {
            Button {model.undo()} label: {Image(systemName:"arrow.uturn.backward")}.buttonStyle(.plain).disabled(model.undoStack.isEmpty).help(L("撤销 ⌘Z"))
            Button {model.redo()} label: {Image(systemName:"arrow.uturn.forward")}.buttonStyle(.plain).disabled(model.redoStack.isEmpty).help(L("重做 ⇧⌘Z"))
        }.fixedSize()
    }

    var actionGroup:some View {
        HStack(spacing:3) {
            Button(action:onPin) {Image(systemName:"pin")}.buttonStyle(.plain).help(L("置顶"))
            Button(action:onOCR) {Image(systemName:"text.viewfinder")}.buttonStyle(.plain).help(L("提取文字"))
            Button(action:onSave) {Image(systemName:"square.and.arrow.down")}.buttonStyle(.plain).help(L("保存"))
            Button(action:onMain) {Image(systemName:"macwindow")}.buttonStyle(.plain).help(L("主窗口"))
        }.fixedSize()
    }

    var endGroup:some View {
        HStack(spacing:4) {
            Button(action:onCancel) {Image(systemName:"xmark")}.buttonStyle(.plain).help(L("取消"))
            Button(action:onCopy) {Label(L("复制"),systemImage:"checkmark")}.buttonStyle(.borderedProminent)
        }.fixedSize()
    }

    var singleRow:some View {
        HStack(spacing:3) {
            toolGroup
            Divider().frame(height:22).padding(.horizontal,10)
            colorWidthGroup
            Divider().frame(height:22).padding(.horizontal,10)
            undoGroup
            Divider().frame(height:22).padding(.horizontal,10)
            actionGroup
            Spacer(minLength:4)
            endGroup
        }
        .controlSize(.small).padding(.horizontal,10)
    }

    var twoRows:some View {
        VStack(spacing:4) {
            HStack(spacing:3) {
                toolGroup
                Divider().frame(height:22).padding(.horizontal,10)
                colorWidthGroup
                Spacer(minLength:0)
            }
            HStack(spacing:3) {
                undoGroup
                Divider().frame(height:22).padding(.horizontal,10)
                actionGroup
                Spacer(minLength:4)
                endGroup
            }
        }
        .controlSize(.small).padding(.horizontal,10).padding(.vertical,4)
    }
}
