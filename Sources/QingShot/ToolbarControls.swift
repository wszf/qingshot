import AppKit
import SwiftUI

@MainActor private final class ColorPanelTarget:NSObject {
    var onColor:((NSColor)->Void)?
    @objc func colorChanged(_ sender:NSColorPanel) {onColor?(sender.color)}
}

struct AnnotationColorControls:View {
    @ObservedObject var model:ShotModel
    var height:CGFloat = 30
    private let presets:[UInt32] = [0xF26C4F,0xF2C94C,0x34C38F,0x3B82F6,0xA855F7]

    var body:some View {
        HStack(spacing:6) {
            ForEach(presets,id:\.self) {hex in colorButton(hex)}
            MoreColorButton(model:model,height:height)
        }.fixedSize()
    }

    private func colorButton(_ hex:UInt32) -> some View {
        let color = NSColor(hex:hex)
        let selected = matches(color)
        return Button {model.color = Color(nsColor:color)} label: {
            ZStack {
                Circle().stroke(selected ? accent : Color.clear,lineWidth:2).frame(width:18,height:18)
                Circle().fill(Color(nsColor:color)).frame(width:14,height:14)
                    .overlay(Circle().stroke(Color.primary.opacity(0.18),lineWidth:0.5))
            }.frame(width:20,height:height)
        }.buttonStyle(.plain).help(L("颜色"))
    }

    private func matches(_ color:NSColor) -> Bool {
        guard let a = NSColor(model.color).usingColorSpace(.deviceRGB),let b = color.usingColorSpace(.deviceRGB) else {return false}
        return abs(a.redComponent-b.redComponent) < 0.01 && abs(a.greenComponent-b.greenComponent) < 0.01 && abs(a.blueComponent-b.blueComponent) < 0.01
    }
}

struct MoreColorButton:View {
    @ObservedObject var model:ShotModel
    var height:CGFloat = 30
    @State private var target = ColorPanelTarget()

    var body:some View {
        Button(action:openPanel) {
            ZStack {
                Circle().fill(AngularGradient(colors:[.red,.orange,.yellow,.green,.blue,.purple,.red],center:.center)).frame(width:14,height:14)
                Image(systemName:"plus").font(.system(size:6,weight:.bold)).foregroundStyle(.white)
            }.frame(width:20,height:height)
        }.buttonStyle(.plain).help(L("更多颜色"))
    }

    private func openPanel() {
        target.onColor = {model.color = Color(nsColor:$0)}
        let panel = NSColorPanel.shared
        panel.setTarget(target)
        panel.setAction(#selector(ColorPanelTarget.colorChanged(_:)))
        panel.color = NSColor(model.color)
        panel.isContinuous = true
        panel.orderFront(nil)
    }
}

struct AnnotationWidthControls:View {
    @ObservedObject var model:ShotModel
    var buttonWidth:CGFloat = 30
    var buttonHeight:CGFloat = 30
    private let widths:[(CGFloat,String)] = [(3,L("细")),(5,L("中")),(9,L("粗"))]

    var body:some View {
        HStack(spacing:2) {
            ForEach(widths,id:\.0) {width,label in widthButton(width,label)}
        }.fixedSize()
    }

    private func widthButton(_ width:CGFloat,_ label:String) -> some View {
        let selected = abs(model.lineWidth-width) < 0.1
        return Button {model.lineWidth = width} label: {
            Capsule().fill(selected ? accent : Color.secondary)
                .frame(width:16,height:max(2,width*0.7))
                .frame(width:buttonWidth,height:buttonHeight)
                .background(selected ? accent.opacity(0.13) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius:7))
        }.buttonStyle(.plain).help(label)
    }
}
