import AppKit

enum MarkTool: String, CaseIterable, Identifiable {
    case arrow, rectangle, ellipse, pen, text, number, highlight, redact, crop
    var id: String { rawValue }
    var label: String { switch self { case .arrow: return L("箭头"); case .rectangle: return L("矩形"); case .ellipse: return L("圆形"); case .pen: return L("画笔"); case .text: return L("文字"); case .number: return L("序号"); case .highlight: return L("高亮"); case .redact: return L("遮盖"); case .crop: return L("裁剪") } }
    var icon: String { switch self { case .arrow: return "arrow.up.right"; case .rectangle: return "rectangle"; case .ellipse: return "circle"; case .pen: return "pencil.tip"; case .text: return "textformat"; case .number: return "1.circle"; case .highlight: return "highlighter"; case .redact: return "rectangle.fill"; case .crop: return "crop" } }
}
struct Mark {
    var tool: MarkTool
    var points: [CGPoint]
    var color: NSColor
    var width: CGFloat
    var text: String = ""
    var rect: CGRect { let a = points.first ?? .zero, b = points.last ?? a; return CGRect(x: min(a.x,b.x), y: min(a.y,b.y), width: abs(b.x-a.x), height: abs(b.y-a.y)) }
}
enum Backdrop: String, CaseIterable, Identifiable {
    case none, mint, dusk, peach, ink
    var label: String { switch self { case .none: return L("原图"); case .mint: return L("薄荷"); case .dusk: return L("暮色"); case .peach: return L("奶油"); case .ink: return L("石墨") } }
    var id: String { rawValue }
    var colors: [NSColor] {
        switch self {
        case .none: return [.clear,.clear]
        case .mint: return [NSColor(hex: 0xBDEBDB),NSColor(hex: 0x4D9C8A)]
        case .dusk: return [NSColor(hex: 0xB8B6EF),NSColor(hex: 0x514A92)]
        case .peach: return [NSColor(hex: 0xFBE4C8),NSColor(hex: 0xE8AB99)]
        case .ink: return [NSColor(hex: 0x4D5665),NSColor(hex: 0x1B2330)]
        }
    }
}
extension NSColor {
    convenience init(hex: UInt32) { self.init(srgbRed: CGFloat((hex >> 16)&255)/255, green: CGFloat((hex >> 8)&255)/255, blue: CGFloat(hex&255)/255, alpha: 1) }
}
extension NSImage {
    var pixelSize: CGSize { if let r = representations.max(by: { $0.pixelsWide < $1.pixelsWide }) { return CGSize(width: r.pixelsWide, height: r.pixelsHigh) }; return size }
    var png: Data? { guard let tiff = tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }; return bitmap.representation(using: .png, properties: [:]) }
}
enum Renderer {
    // All editing coordinates use physical image pixels with a top-left origin.
    static func bitmap(size: CGSize, draw: () -> Void) -> NSImage {
        let w = max(1,Int(size.width)), h = max(1,Int(size.height))
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = CGSize(width: w,height: h)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let ctx = NSGraphicsContext.current!.cgContext
        ctx.translateBy(x: 0,y: CGFloat(h)); ctx.scaleBy(x: 1,y: -1)
        NSGraphicsContext.current = NSGraphicsContext(cgContext:ctx,flipped:true)
        draw()
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: rep.size); image.addRepresentation(rep); return image
    }
    static func drawImage(_ image: NSImage, in rect: CGRect) {
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
    }
    static func drawMark(_ m: Mark) {
        guard let a = m.points.first, let b = m.points.last else { return }
        let p = NSBezierPath(); p.lineWidth = m.width; p.lineCapStyle = .round; p.lineJoinStyle = .round
        m.color.setStroke(); m.color.setFill()
        switch m.tool {
        case .arrow:
            p.move(to: a); p.line(to: b); p.stroke()
            let angle = atan2(b.y-a.y,b.x-a.x), length = max(16,m.width*4)
            p.move(to: CGPoint(x: b.x-length*cos(angle-0.48),y: b.y-length*sin(angle-0.48))); p.line(to: b)
            p.line(to: CGPoint(x: b.x-length*cos(angle+0.48),y: b.y-length*sin(angle+0.48))); p.stroke()
        case .rectangle: NSBezierPath(rect: m.rect).withWidth(m.width).stroke()
        case .ellipse: NSBezierPath(ovalIn: m.rect).withWidth(m.width).stroke()
        case .pen:
            p.move(to: a); for pt in m.points.dropFirst() { p.line(to: pt) }; if m.points.count == 1 { p.line(to: CGPoint(x:a.x+0.1,y:a.y)) }; p.stroke()
        case .highlight: m.color.withAlphaComponent(0.28).setFill(); NSBezierPath(rect:m.rect).fill()
        case .redact: NSColor(hex:0x141920).setFill(); NSBezierPath(rect:m.rect).fill()
        case .text:
            (m.text as NSString).draw(at:a,withAttributes:[.font:NSFont.systemFont(ofSize:max(18,m.width*6),weight:.semibold),.foregroundColor:m.color])
        case .number:
            let r = max(16,m.width*4); NSBezierPath(ovalIn:CGRect(x:a.x-r,y:a.y-r,width:r*2,height:r*2)).fill()
            let attrs: [NSAttributedString.Key:Any] = [.font:NSFont.systemFont(ofSize:r*1.1,weight:.bold),.foregroundColor:NSColor.white]
            let size = (m.text as NSString).size(withAttributes:attrs)
            (m.text as NSString).draw(at:CGPoint(x:a.x-size.width/2,y:a.y-size.height/2),withAttributes:attrs)
        case .crop:
            NSColor.systemTeal.setStroke(); p.appendRect(m.rect); p.setLineDash([8,5], count:2, phase:0); p.stroke()
        }
    }
    static func render(_ image: NSImage, marks: [Mark], backdrop: Backdrop = .none, padding: CGFloat = 64) -> NSImage {
        let s = image.pixelSize, pad = backdrop == .none ? 0 : padding
        return bitmap(size:CGSize(width:s.width+pad*2,height:s.height+pad*2)) {
            let full = CGRect(x:0,y:0,width:s.width+pad*2,height:s.height+pad*2)
            if backdrop != .none { NSGradient(colors:backdrop.colors)!.draw(in:full,angle:35) }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current!.cgContext.translateBy(x:pad,y:pad)
            let rect = CGRect(origin:.zero,size:s)
            if backdrop != .none {
                let rounded = NSBezierPath(roundedRect:rect,xRadius:18,yRadius:18)
                NSGraphicsContext.saveGraphicsState()
                let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.28); shadow.shadowBlurRadius = 22; shadow.shadowOffset = CGSize(width:0,height:8); shadow.set(); NSColor.white.setFill(); rounded.fill()
                NSGraphicsContext.restoreGraphicsState(); rounded.addClip()
            }
            drawImage(image,in:rect); for m in marks { drawMark(m) }
            NSGraphicsContext.restoreGraphicsState()
        }
    }
    static func crop(_ image: NSImage, rect: CGRect) -> NSImage {
        let r = rect.integral.intersection(CGRect(origin:.zero,size:image.pixelSize))
        return bitmap(size:r.size) { NSGraphicsContext.current!.cgContext.translateBy(x:-r.minX,y:-r.minY); drawImage(image,in:CGRect(origin:.zero,size:image.pixelSize)) }
    }
    static func stitch(_ images: [NSImage], overlap: CGFloat) -> NSImage? {
        guard let first = images.first else { return nil }
        let width = first.pixelSize.width
        let heights = images.map { $0.pixelSize.height * width / $0.pixelSize.width }
        let joins = heights.dropFirst().enumerated().map { min(overlap,min(heights[$0.offset],$0.element)-1) }
        let total = heights.reduce(0,+)-joins.reduce(0,+)
        guard width*total <= 100_000_000, total <= 32000 else { return nil }
        return bitmap(size:CGSize(width:width,height:total)) {
            var y: CGFloat = 0
            for (i,img) in images.enumerated() {
                if i > 0 { y -= joins[i-1] }
                drawImage(img,in:CGRect(x:0,y:y,width:width,height:heights[i])); y += heights[i]
            }
        }
    }
    static func demo() -> NSImage {
        bitmap(size:CGSize(width:1200,height:760)) {
            NSColor(hex:0xF8FAF8).setFill(); NSBezierPath(rect:CGRect(x:0,y:0,width:1200,height:760)).fill()
            NSColor(hex:0xE5ECE7).setFill(); NSBezierPath(rect:CGRect(x:0,y:0,width:1200,height:56)).fill()
            for (i,c) in [NSColor.systemRed,.systemYellow,.systemGreen].enumerated() { c.setFill(); NSBezierPath(ovalIn:CGRect(x:24+i*23,y:22,width:12,height:12)).fill() }
            func txt(_ text:String,_ x:CGFloat,_ y:CGFloat,_ size:CGFloat,_ color:NSColor,_ weight:NSFont.Weight = .regular) { (text as NSString).draw(at:CGPoint(x:x,y:y),withAttributes:[.font:NSFont.systemFont(ofSize:size,weight:weight),.foregroundColor:color]) }
            txt(L("QING STUDIO  /  工作空间"),64,100,18,NSColor(hex:0x5C786B),.semibold)
            txt(L("把想法，变成看得见的进展。"),64,158,42,NSColor(hex:0x1D352C),.bold)
            txt("Capture ideas. Make them clear.",64,223,23,NSColor(hex:0x75847D))
            let labels = [L("设计探索"),L("原生体验"),L("准备分享")]
            for i in 0..<3 {
                let x = CGFloat(64+i*364)
                NSColor.white.setFill(); NSBezierPath(roundedRect:CGRect(x:x,y:310,width:336,height:275),xRadius:20,yRadius:20).fill()
                txt("0\(i+1)",x+28,340,18,NSColor(hex:0x688577),.medium)
                txt(labels[i],x+28,393,28,NSColor(hex:0x203D31),.semibold)
                txt([L("清晰表达每一个细节"),L("让工具融入你的工作流"),L("用一张图，说清一件事")][i],x+28,440,17,NSColor(hex:0x74857C))
                NSColor(hex:0xDDEFE5).setFill(); NSBezierPath(roundedRect:CGRect(x:x+28,y:508,width:200,height:12),xRadius:6,yRadius:6).fill()
            }
            txt(L("试试箭头、标注与背景美化"),64,649,19,NSColor(hex:0x597568))
        }
    }
}
extension NSBezierPath { func withWidth(_ width:CGFloat) -> NSBezierPath { lineWidth = width; return self } }
