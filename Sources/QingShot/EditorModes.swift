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

enum CaptureKeyAction {case cancel, copy, save, undo, redo, tool(Int)}
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
    override var canBecomeKey:Bool {true}
    override var canBecomeMain:Bool {true}
}

@MainActor final class PostCaptureController {
    private unowned let model:ShotModel
    private var panel:PostCapturePanel?
    private var monitor:Any?

    init(model:ShotModel) {self.model = model}

    func show() {
        close()
        guard let image = model.image,let screen = NSScreen.screens.first(where: {$0.frame.contains(NSEvent.mouseLocation)}) ?? NSScreen.main else {return}
        let size = PostCaptureLayout.panelSize(image:image.pixelSize,pixelScale:screen.backingScaleFactor,screen:screen.visibleFrame)
        let panel = PostCapturePanel(contentRect:NSRect(origin:.zero,size:size),styleMask:[.borderless],backing:.buffered,defer:false)
        panel.isReleasedWhenClosed = false;panel.isOpaque = false;panel.backgroundColor = .clear;panel.hasShadow = true
        panel.level = .floating;panel.hidesOnDeactivate = false;panel.isFloatingPanel = true
        panel.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary]
        let host = NSHostingView(rootView:PostCaptureEditorView(model:model, close:{ [weak self] in self?.close() }, copyAndClose:{ [weak self] in self?.copyAndClose() }, openMain:{ [weak self] in self?.openMain() }, openOCR:{ [weak self] in self?.openOCR() }))
        host.appearance = NSAppearance(named:.aqua)
        panel.appearance = NSAppearance(named:.aqua)
        panel.contentView = host
        panel.setFrame(NSRect(origin:PostCaptureLayout.centeredOrigin(size:size,in:screen.visibleFrame),size:size),display:false)
        self.panel = panel
        model.quickPanel = panel
        NSApp.unhide(nil);NSApp.activate(ignoringOtherApps:true);panel.makeKeyAndOrderFront(nil)
        monitor = NSEvent.addLocalMonitorForEvents(matching:.keyDown) { [weak self] event in
            guard let self,let panel = self.panel,panel.isVisible,event.window === panel,CaptureKeyRouter.isTextInput(panel) == false else {return event}
            guard let action = CaptureKeyRouter.action(event) else {return event}
            switch action {
            case .cancel: self.close()
            case .copy: self.copyAndClose()
            case .save: self.model.save()
            case .undo: self.model.undo()
            case .redo: self.model.redo()
            case .tool(let n): if MarkTool.allCases.indices.contains(n-1) {self.model.tool = MarkTool.allCases[n-1]}
            }
            return nil
        }
    }

    func close() {
        if let monitor {NSEvent.removeMonitor(monitor);self.monitor = nil}
        panel?.orderOut(nil);panel = nil
        if model.quickPanel?.isVisible == false {model.quickPanel = nil}
    }
    func copyAndClose() {model.copy();model.status = L("已复制图片，可粘贴到其他应用");close()}
    func openMain() {close();model.showWindow()}
    func openOCR() {close();model.showWindow();model.recognize()}
}

struct PostCaptureEditorView: View {
    @ObservedObject var languageStore = LanguageStore.shared
    @ObservedObject var model:ShotModel
    let close:()->Void
    let copyAndClose:()->Void
    let openMain:()->Void
    let openOCR:()->Void

    var body: some View {
        VStack(spacing:0) {
            topBar.frame(height:54)
            Divider()
            CanvasBridge(model:model, inset:0, maxScale:1).padding(16).frame(maxWidth:.infinity,maxHeight:.infinity)
            Divider()
            bottomBar.frame(height:58)
        }
        .background(Color(nsColor:NSColor(hex:0xFAFBF8)))
        .clipShape(RoundedRectangle(cornerRadius:14))
        .overlay(RoundedRectangle(cornerRadius:14).stroke(.black.opacity(0.14)))
        .tint(accent).preferredColorScheme(.light)
    }

    var topBar: some View {
        HStack(spacing:3) {
            ForEach(MarkTool.allCases) {tool in
                Button {model.tool = tool} label: {
                    Image(systemName:tool.icon).font(.system(size:14,weight:.medium)).frame(width:30,height:30)
                        .foregroundStyle(model.tool == tool ? accent : Color.secondary)
                        .background(model.tool == tool ? accent.opacity(0.13) : .clear).clipShape(RoundedRectangle(cornerRadius:7))
                }.buttonStyle(.plain).help(tool.label)
            }
            Divider().frame(height:24).padding(.horizontal,6)
            ColorPicker(L("颜色"),selection:$model.color,supportsOpacity:false).labelsHidden().frame(width:30)
            Picker(L("线宽"),selection:$model.lineWidth) {Text(L("细")).tag(3.0);Text(L("中")).tag(5.0);Text(L("粗")).tag(9.0)}.labelsHidden().pickerStyle(.menu).frame(width:64)
            Divider().frame(height:24).padding(.horizontal,6)
            Button {model.undo()} label: {Image(systemName:"arrow.uturn.backward")}.buttonStyle(.plain).disabled(model.undoStack.isEmpty).help(L("撤销 ⌘Z"))
            Button {model.redo()} label: {Image(systemName:"arrow.uturn.forward")}.buttonStyle(.plain).disabled(model.redoStack.isEmpty).help(L("重做 ⇧⌘Z"))
            Spacer(minLength:8)
            Button(action:close) {Image(systemName:"xmark").font(.system(size:13,weight:.semibold)).foregroundStyle(.secondary).frame(width:28,height:28)}.buttonStyle(.plain).help(L("关闭"))
        }.padding(.horizontal,14)
    }

    var bottomBar: some View {
        HStack(spacing:9) {
            backgrounds
            Spacer(minLength:6)
            ImageDragChip(model:model)
            Button(L("提取文字")) {openOCR()}
            Button(L("置顶")) {model.pin()}
            Button(L("保存")) {model.save()}
            Button(L("主窗口")) {openMain()}
            Button(action:copyAndClose) {Label(L("复制"),systemImage:"doc.on.doc")}.buttonStyle(.borderedProminent)
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
        let fill = background == .none ? Color.white : Color(nsColor:background.colors[1])
        return Button {model.backdrop = background} label: {
            Circle().fill(fill).frame(width:18,height:18).overlay(Circle().stroke(selected ? accent : Color.gray.opacity(0.3),lineWidth:selected ? 2 : 1))
        }.buttonStyle(.plain).help(background.label)
    }
}

struct ImageDragChip: View {
    @ObservedObject var model:ShotModel
    var body: some View {
        Image(systemName:"square.and.arrow.up.on.square").font(.system(size:12)).frame(width:32,height:26)
            .background(.black.opacity(0.05)).clipShape(RoundedRectangle(cornerRadius:5))
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
        HStack(spacing:3) {
            ForEach(MarkTool.allCases) {tool in
                Button {model.tool = tool} label: {
                    Image(systemName:tool.icon).font(.system(size:13,weight:.medium)).frame(width:27,height:28)
                        .foregroundStyle(model.tool == tool ? accent : Color.secondary)
                        .background(model.tool == tool ? accent.opacity(0.13) : .clear).clipShape(RoundedRectangle(cornerRadius:6))
                }.buttonStyle(.plain).help(tool.label)
            }
            Divider().frame(height:22).padding(.horizontal,5)
            ColorPicker(L("颜色"),selection:$model.color,supportsOpacity:false).labelsHidden().frame(width:26)
            Picker(L("线宽"),selection:$model.lineWidth) {Text(L("细")).tag(3.0);Text(L("中")).tag(5.0);Text(L("粗")).tag(9.0)}.labelsHidden().pickerStyle(.segmented).frame(width:112)
            Divider().frame(height:22).padding(.horizontal,5)
            Button {model.undo()} label: {Image(systemName:"arrow.uturn.backward")}.buttonStyle(.plain).disabled(model.undoStack.isEmpty).help(L("撤销 ⌘Z"))
            Button {model.redo()} label: {Image(systemName:"arrow.uturn.forward")}.buttonStyle(.plain).disabled(model.redoStack.isEmpty).help(L("重做 ⇧⌘Z"))
            Divider().frame(height:22).padding(.horizontal,5)
            Button(action:onPin) {Image(systemName:"pin")}.buttonStyle(.plain).help(L("置顶"))
            Button(action:onOCR) {Image(systemName:"text.viewfinder")}.buttonStyle(.plain).help(L("提取文字"))
            Button(action:onSave) {Image(systemName:"square.and.arrow.down")}.buttonStyle(.plain).help(L("保存"))
            Button(action:onMain) {Image(systemName:"macwindow")}.buttonStyle(.plain).help(L("主窗口"))
            Spacer(minLength:4)
            Button(action:onCancel) {Image(systemName:"xmark")}.buttonStyle(.plain).help(L("取消"))
            Button(action:onCopy) {Label(L("复制"),systemImage:"checkmark")}.buttonStyle(.borderedProminent)
        }
        .controlSize(.small).padding(.horizontal,10).frame(height:46)
        .background(.regularMaterial).clipShape(RoundedRectangle(cornerRadius:12))
        .overlay(RoundedRectangle(cornerRadius:12).stroke(.black.opacity(0.14)))
        .tint(accent).preferredColorScheme(.light)
    }
}
