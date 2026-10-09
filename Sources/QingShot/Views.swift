import AppKit
import SwiftUI

let accent = Color(red:0.20,green:0.48,blue:0.39)
struct ContentView: View {
    @ObservedObject var languageStore = LanguageStore.shared
    @ObservedObject var shortcuts = ShortcutStore.shared
    @ObservedObject var model: ShotModel
    var body: some View {
        HStack(spacing:0) {
            sidebar.frame(width:Localization.languageCode() == "en" ? 248 : 218)
            Divider()
            VStack(spacing:0) {
                header
                Divider()
                if model.image != nil {
                    tools
                    Divider()
                    CanvasBridge(model:model).frame(maxWidth:.infinity,maxHeight:.infinity).background(Color(nsColor:NSColor(hex:0xE8ECE8)))
                    Divider()
                    bottom
                } else {welcome.frame(maxWidth:.infinity,maxHeight:.infinity)}
                HStack(spacing:8) {
                    Circle().fill(model.recording ? Color.red : accent).frame(width:6,height:6)
                    Text(model.status).font(.system(size:11)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    if model.busy || model.recordStarting {ProgressView().controlSize(.small)}
                    Text(L("本地处理")).font(.system(size:10)).foregroundStyle(.tertiary)
                }.padding(.horizontal,18).frame(height:34).background(.background)
            }
        }.tint(accent).frame(minWidth:1080,minHeight:700).environment(\.locale,Locale(identifier:Localization.languageCode()))
        .sheet(isPresented:$model.showOCR) {
            VStack(alignment:.leading,spacing:16) {
                HStack {Label(L("提取文字"),systemImage:"text.viewfinder").font(.title2.bold()); Spacer(); Text(L("本机识别")).foregroundStyle(.secondary)}
                TextEditor(text:$model.ocrText).font(.system(size:15)).padding(8).background(Color(nsColor:.textBackgroundColor)).clipShape(RoundedRectangle(cornerRadius:10))
                HStack {Text(L("复制前可以直接修改识别结果。")).font(.caption).foregroundStyle(.secondary); Spacer(); Button(L("关闭")) {model.showOCR = false}; Button(L("复制文字")) {NSPasteboard.general.clearContents(); NSPasteboard.general.setString(model.ocrText,forType:.string); model.status = L("已复制识别文字");model.showOCR = false}.buttonStyle(.borderedProminent).disabled(model.ocrText.isEmpty)}
            }.padding(24).frame(width:620,height:440)
        }
    }
    var sidebar: some View {
        VStack(alignment:.leading,spacing:0) {
            HStack(spacing:10) {
                Image(systemName:"viewfinder").font(.system(size:25,weight:.semibold)).foregroundStyle(accent).frame(width:42,height:42).background(accent.opacity(0.1)).clipShape(RoundedRectangle(cornerRadius:12))
                VStack(alignment:.leading,spacing:2) {Text(L("轻截图")).font(.system(size:20,weight:.bold)); Text("QINGSHOT").font(.system(size:9,weight:.semibold,design:.monospaced)).tracking(2).foregroundStyle(.secondary)}
            }.padding(.horizontal,20).padding(.top,22).padding(.bottom,25)
            Button {model.capture("area")} label: {HStack {Image(systemName:"plus"); Text(L("新建截图")).fontWeight(.semibold); Spacer(); Text(shortcuts.display(.area)).opacity(0.75)}.padding(.vertical,9).padding(.horizontal,10)}.buttonStyle(.borderedProminent).padding(.horizontal,14).disabled(model.busy || model.recording || model.recordStarting)
            VStack(spacing:3) {
                sideButton(L("窗口截图"),"macwindow",shortcuts.display(.window)) {model.capture("window")}
                sideButton(L("全屏截图"),"display",shortcuts.display(.full)) {model.capture("full")}
                sideButton(L("导入图片"),"photo.on.rectangle","⌘O") {model.openImage()}
                sideButton(L("拼接长图"),"rectangle.on.rectangle","") {model.stitch()}
                sideButton(model.recording ? L("停止录屏") : L("录制主屏"),"record.circle",model.recording ? "●" : "") {model.recording ? model.stopRecording() : model.startRecording()}
            }.padding(.horizontal,14).padding(.top,12)
            HStack {Text(L("最近截图")).font(.system(size:11,weight:.semibold)); Spacer(); Text("\(model.history.count) / 30").font(.system(size:10,design:.monospaced))}.foregroundStyle(.secondary).padding(.horizontal,20).padding(.top,28).padding(.bottom,10)
            ScrollView {
                LazyVStack(spacing:8) {
                    ForEach(model.history) {item in
                        Button {model.load(item.image,name:L("历史截图"),save:false)} label: {
                            HStack(spacing:10) {
                                Image(nsImage:item.image).resizable().scaledToFit().frame(width:55,height:42).background(Color.white.opacity(0.5)).clipShape(RoundedRectangle(cornerRadius:5))
                                VStack(alignment:.leading,spacing:4) {Text(item.date,format:.dateTime.hour().minute()).font(.system(size:12,weight:.medium)); Text("\(Int(item.image.pixelSize.width)) × \(Int(item.image.pixelSize.height))").font(.system(size:9,design:.monospaced)).foregroundStyle(.secondary)}
                                Spacer(minLength:0)
                            }.padding(8).background(.white.opacity(0.50)).clipShape(RoundedRectangle(cornerRadius:9))
                        }.buttonStyle(.plain).contextMenu {Button(L("从历史记录删除"),role:.destructive) {model.deleteHistory(item)}}
                    }
                    if model.history.isEmpty {Text(L("截图与导入图片会保存在这里\n标注后请保存导出")).font(.system(size:11)).foregroundStyle(.tertiary).lineSpacing(5).frame(maxWidth:.infinity,alignment:.leading).padding(8)}
                }.padding(.horizontal,14)
            }
            Spacer(minLength:8)
            Button {(NSApp.delegate as? AppDelegate)?.settings()} label: {HStack {Image(systemName:"gearshape"); Text(L("设置与快捷键")); Spacer(); Text("⌘,").font(.system(size:10,design:.monospaced))}.font(.system(size:11)).foregroundStyle(.secondary).padding(18)}.buttonStyle(.plain)
        }.background(Color(nsColor:NSColor(hex:0xF2F5F1)))
    }
    func sideButton(_ title:String,_ icon:String,_ key:String,action:@escaping () -> Void) -> some View {
        Button(action:action) {HStack {Image(systemName:icon).frame(width:20).foregroundStyle(accent); Text(title); Spacer(); Text(key).font(.system(size:10,design:.monospaced)).foregroundStyle(.tertiary)}.font(.system(size:12)).padding(.vertical,9).padding(.horizontal,8)}.buttonStyle(.plain).disabled(model.busy || model.recordStarting)
    }
    var header: some View {
        HStack(spacing:14) {
            VStack(alignment:.leading,spacing:3) {Text(model.image == nil ? L("捕捉。标记。分享。") : model.name).font(.system(size:15,weight:.semibold)); Text(model.image.map {"\(Int($0.pixelSize.width)) × \(Int($0.pixelSize.height)) px  ·  PNG"} ?? L("让每一次表达，都更清晰。")).font(.system(size:10,design:.monospaced)).foregroundStyle(.secondary)}
            Spacer()
            Button {model.pin()} label: {Image(systemName:"pin")}.help(L("贴图置顶")).disabled(model.image == nil)
            Button {model.recognize()} label: {Label(L("提取文字"),systemImage:"text.viewfinder")}.disabled(model.image == nil || model.busy)
            Button {model.copy()} label: {Label(L("复制"),systemImage:"doc.on.doc")}.disabled(model.image == nil)
            Button {model.save()} label: {Label(L("导出"),systemImage:"square.and.arrow.up")}.buttonStyle(.borderedProminent).disabled(model.image == nil)
        }.controlSize(.regular).padding(.horizontal,22).frame(height:76)
    }
    var tools: some View {
        HStack(spacing:4) {
            ForEach(MarkTool.allCases) {t in
                Button {model.tool = t} label: {VStack(spacing:4) {Image(systemName:t.icon).font(.system(size:15,weight:.medium)).frame(height:19); Text(t.label).font(.system(size:9))}.frame(width:Localization.languageCode() == "en" ? 49 : 42,height:46).foregroundStyle(model.tool == t ? accent : Color.secondary).background(model.tool == t ? accent.opacity(0.12) : .clear).clipShape(RoundedRectangle(cornerRadius:8))}.buttonStyle(.plain).help(t.label)
            }
            Divider().frame(height:28).padding(.horizontal,8)
            ColorPicker(L("颜色"),selection:$model.color,supportsOpacity:false).labelsHidden().frame(width:30)
            Picker(L("线宽"),selection:$model.lineWidth) {Text(L("细")).tag(3.0);Text(L("中")).tag(5.0);Text(L("粗")).tag(9.0)}.labelsHidden().frame(width:Localization.languageCode() == "en" ? 85 : 65)
            Spacer(minLength:0)
            Button {model.undo()} label: {Image(systemName:"arrow.uturn.backward")}.disabled(model.undoStack.isEmpty).help(L("撤销 ⌘Z"))
            Button {model.redo()} label: {Image(systemName:"arrow.uturn.forward")}.disabled(model.redoStack.isEmpty).help(L("重做 ⇧⌘Z"))
        }.padding(.horizontal,16).frame(height:66)
    }
    var bottom: some View {
        HStack(spacing:13) {
            Label(L("背景"),systemImage:"square.stack.3d.up").font(.system(size:11)).foregroundStyle(.secondary)
            ForEach(Backdrop.allCases) {bg in
                Button {model.backdrop = bg} label: {HStack(spacing:5) {RoundedRectangle(cornerRadius:4).fill(LinearGradient(colors:bg == .none ? [.white,Color.gray.opacity(0.1)] : bg.colors.map {Color(nsColor:$0)},startPoint:.topLeading,endPoint:.bottomTrailing)).frame(width:20,height:20).overlay(RoundedRectangle(cornerRadius:4).stroke(.gray.opacity(0.2))); Text(bg.label).font(.system(size:11))}.padding(5).background(model.backdrop == bg ? accent.opacity(0.12) : .clear).clipShape(RoundedRectangle(cornerRadius:6))}.buttonStyle(.plain)
            }
            Spacer()
            if model.backdrop != .none {Text(L("留白")).font(.caption).foregroundStyle(.secondary); Slider(value:$model.padding,in:24...160,step:8).frame(width:85)}
            Text(L("自适应预览")).font(.system(size:10)).foregroundStyle(.tertiary)
        }.padding(.horizontal,20).frame(height:55)
    }
    var welcome: some View {
        VStack(alignment:.leading,spacing:0) {
            HStack {Image(systemName:"sparkle");Text(L("少一点操作，多一点专注")).tracking(2)}.font(.system(size:11,weight:.medium)).foregroundStyle(accent).padding(.bottom,20)
            Text(L("好想法，\n一截即得。")).font(.system(size:52,weight:.bold)).tracking(-1).lineSpacing(4).foregroundStyle(Color(nsColor:NSColor(hex:0x203B30)))
            Text(L("从屏幕上的灵感，到清晰的表达。\n截图、标注、提取文字，在一个轻巧的工具里完成。")).font(.system(size:15)).foregroundStyle(.secondary).lineSpacing(7).padding(.top,20)
            HStack(spacing:12) {Button {model.capture("area")} label: {Label(L("开始截图"),systemImage:"viewfinder").padding(.horizontal,12).padding(.vertical,8)}.buttonStyle(.borderedProminent); Button(L("试用演示图")) {model.demo()}.buttonStyle(.bordered).controlSize(.large)}.padding(.top,30)
            HStack(spacing:24) {feature("viewfinder",L("快捷捕捉"),L("全局快捷键，随时截取")); feature("pencil.tip.crop.circle",L("清晰标注"),L("箭头、文字与重点遮盖")); feature("sparkles",L("轻松分享"),L("背景美化，一键复制"))}.padding(.top,48)
            Text(L("首次截图需允许屏幕录制权限 · 最近 30 张原图保存在本机")).font(.system(size:10)).foregroundStyle(.tertiary).padding(.top,36)
        }.padding(45).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.leading).background(Color(nsColor:NSColor(hex:0xFAFBF8)))
    }
    func feature(_ icon:String,_ title:String,_ subtitle:String) -> some View {VStack(alignment:.leading,spacing:10) {Image(systemName:icon).font(.system(size:22)).foregroundStyle(accent);Text(title).font(.system(size:13,weight:.semibold));Text(subtitle).font(.system(size:10)).foregroundStyle(.secondary)}.frame(maxWidth:.infinity,alignment:.leading)}
}
struct QuickView: View {
    @ObservedObject var languageStore = LanguageStore.shared
    @ObservedObject var model:ShotModel
    var body: some View {
        VStack(spacing:12) {
            HStack {Text(L("已捕捉")).font(.system(size:12,weight:.semibold)); Spacer(); Button {model.quickPanel?.orderOut(nil)} label: {Image(systemName:"xmark")}.buttonStyle(.plain)}
            if let image = model.image {Image(nsImage:image).resizable().scaledToFit().frame(height:128).frame(maxWidth:.infinity).background(.black.opacity(0.04)).clipShape(RoundedRectangle(cornerRadius:8))}
            HStack {Button(L("标注")) {model.quickPanel?.orderOut(nil); model.showWindow()}; Button(L("置顶")) {model.pin()}; Spacer(); Button(L("复制")) {model.copy();model.quickPanel?.orderOut(nil)}.buttonStyle(.borderedProminent)}
        }.padding(16).background(.regularMaterial).clipShape(RoundedRectangle(cornerRadius:16)).tint(accent).padding(2)
    }
}
struct CanvasBridge:NSViewRepresentable {
    @ObservedObject var model:ShotModel
    func makeNSView(context:Context) -> EditorCanvas {let v = EditorCanvas(); v.model = model; return v}
    func updateNSView(_ view:EditorCanvas,context:Context) {view.model = model; view.preview = model.output(); view.needsDisplay = true}
}
final class EditorCanvas:NSView {
    var model:ShotModel!
    var preview:NSImage?
    var draft:Mark?
    override var isFlipped:Bool {true}
    override var acceptsFirstResponder:Bool {true}
    var outputRect:CGRect {
        guard let preview else {return .zero}; let s = preview.pixelSize
        let scale = min((bounds.width-64)/s.width,(bounds.height-64)/s.height)
        let size = CGSize(width:s.width*scale,height:s.height*scale)
        return CGRect(x:(bounds.width-size.width)/2,y:(bounds.height-size.height)/2,width:size.width,height:size.height)
    }
    var scale:CGFloat {guard let preview else {return 1}; return outputRect.width/preview.pixelSize.width}
    var imageRect:CGRect {let pad = model.backdrop == .none ? 0 : model.padding*scale; return outputRect.insetBy(dx:pad,dy:pad)}
    override func draw(_ dirtyRect:NSRect) {
        guard let preview else {return}; Renderer.drawImage(preview,in:outputRect)
        if let draft {
            NSGraphicsContext.saveGraphicsState(); NSBezierPath(rect:imageRect).addClip()
            NSGraphicsContext.current!.cgContext.translateBy(x:imageRect.minX,y:imageRect.minY); NSGraphicsContext.current!.cgContext.scaleBy(x:scale,y:scale)
            Renderer.drawMark(draft); NSGraphicsContext.restoreGraphicsState()
        }
    }
    func imagePoint(_ event:NSEvent) -> CGPoint {let p = convert(event.locationInWindow,from:nil); let s = model.image?.pixelSize ?? .zero; return CGPoint(x:min(s.width,max(0,(p.x-imageRect.minX)/scale)),y:min(s.height,max(0,(p.y-imageRect.minY)/scale)))}
    override func mouseDown(with event:NSEvent) {
        guard imageRect.contains(convert(event.locationInWindow,from:nil)) else {return}
        window?.makeFirstResponder(self)
        let pt = imagePoint(event)
        var m = Mark(tool:model.tool,points:[pt],color:NSColor(model.color),width:model.lineWidth)
        if model.tool == .text {
            let a = NSAlert(); a.messageText = L("添加文字"); let field = NSTextField(string:""); field.frame = NSRect(x:0,y:0,width:300,height:28); a.accessoryView = field; a.addButton(withTitle:L("添加")); a.addButton(withTitle:L("取消")); a.window.initialFirstResponder = field
            if a.runModal() == .alertFirstButtonReturn,!field.stringValue.isEmpty {m.text = field.stringValue; model.add(m)}
        } else if model.tool == .number {m.text = "\(model.marks.filter {$0.tool == .number}.count+1)";model.add(m)}
        else {draft = m;needsDisplay = true}
    }
    override func mouseDragged(with event:NSEvent) {guard var m = draft else {return}; let p = imagePoint(event); if m.tool == .pen || m.points.count == 1 {m.points.append(p)} else {m.points[m.points.count-1] = p};draft = m;needsDisplay = true}
    override func mouseUp(with event:NSEvent) {guard let m = draft else {return};draft = nil;if m.tool == .crop {model.crop(m.rect)} else if m.tool == .pen || m.rect.width+m.rect.height > 3 {model.add(m)};needsDisplay = true}
    override func keyDown(with event:NSEvent) {if event.keyCode == 53 {draft = nil;needsDisplay = true} else {super.keyDown(with:event)}}
    override func resetCursorRects() {addCursorRect(imageRect,cursor:.crosshair)}
}
