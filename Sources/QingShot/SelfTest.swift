import AppKit
import Vision

enum SelfTest {
    static func run() {
        var failures = 0
        func check(_ condition:Bool,_ label:String) {print("\(condition ? "PASS" : "FAIL") \(label)");if !condition {failures += 1}}
        let escape = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:0,context:nil,characters:"\u{1b}",charactersIgnoringModifiers:"\u{1b}",isARepeat:false,keyCode:53)!
        check(CaptureKeyRouter.action(escape) == .cancel,"Esc key routes to cancel")
        let appearanceSuite = "qingshot.appearance.self-test"
        let appearanceDefaults = UserDefaults(suiteName:appearanceSuite)!
        appearanceDefaults.removePersistentDomain(forName:appearanceSuite)
        check(AppAppearance.stored(in:appearanceDefaults) == .system,"Appearance defaults to system")
        appearanceDefaults.set(AppAppearance.dark.rawValue,forKey:AppAppearance.defaultsKey)
        check(AppAppearance.stored(in:appearanceDefaults) == .dark,"Appearance setting persists")
        appearanceDefaults.removePersistentDomain(forName:appearanceSuite)
        check(AppAppearance.light.appearance?.name == .aqua && AppAppearance.dark.appearance?.name == .darkAqua && AppAppearance.system.appearance == nil,"Appearance maps to NSAppearance")
        let suite = "qingshot.post-capture.self-test"
        let defaults = UserDefaults(suiteName:suite)!
        defaults.removePersistentDomain(forName:suite)
        check(PostCaptureMode.stored(in:defaults) == .editor,"Post-capture editing defaults to centered editor")
        PostCaptureMode.save(.inline,in:defaults)
        check(PostCaptureMode.stored(in:defaults) == .inline,"Post-capture editing mode persists")
        defaults.removePersistentDomain(forName:suite)
        let panelScreen = NSRect(x:0,y:0,width:1512,height:949)
        let bigPanel = PostCaptureLayout.panelSize(image:CGSize(width:3024,height:1964),pixelScale:2,screen:panelScreen)
        check(bigPanel.width <= panelScreen.width*0.7+0.5 && bigPanel.height <= panelScreen.height*0.7+0.5,"Centered editor stays within 70% of the screen")
        check(bigPanel.height > 500,"Large capture fills the available panel height")
        let smallPanel = PostCaptureLayout.panelSize(image:CGSize(width:400,height:300),pixelScale:2,screen:panelScreen)
        check(smallPanel.width == PostCaptureLayout.minWidth,"Small capture keeps the minimum panel width")
        check(PostCaptureLayout.canvasScale(image:CGSize(width:400,height:300),pixelScale:2,available:CGSize(width:600,height:400)) == 1,"Small capture is not enlarged")
        let centered = PostCaptureLayout.centeredOrigin(size:CGSize(width:600,height:400),in:panelScreen)
        check(centered.x == panelScreen.midX-300 && centered.y == panelScreen.midY-200,"Centered editor is centered on its screen")
        let toolbarScreen = NSRect(x:-3008,y:-669,width:3008,height:1692)
        let toolbarSize = CGSize(width:700,height:44)
        let topSelection = NSRect(x:-2000,y:700,width:400,height:300)
        let toolbarBelow = InlineToolbarLayout.frame(selection:topSelection,size:toolbarSize,screen:toolbarScreen)
        check(toolbarBelow.maxY <= topSelection.minY,"Inline toolbar is placed below the selection")
        let bottomSelection = NSRect(x:-2000,y:-650,width:400,height:250)
        let toolbarAbove = InlineToolbarLayout.frame(selection:bottomSelection,size:toolbarSize,screen:toolbarScreen)
        check(toolbarAbove.minY >= bottomSelection.maxY,"Inline toolbar moves above when the bottom is full")
        let tallSelection = NSRect(x:-2000,y:-600,width:400,height:1500)
        let toolbarInside = InlineToolbarLayout.frame(selection:tallSelection,size:toolbarSize,screen:toolbarScreen)
        check(toolbarInside.minY >= toolbarScreen.minY+7.5 && toolbarInside.maxY <= toolbarScreen.maxY-7.5,"Inline toolbar never leaves the screen")
        let edgeSelection = NSRect(x:-3005,y:0,width:100,height:100)
        let toolbarEdge = InlineToolbarLayout.frame(selection:edgeSelection,size:toolbarSize,screen:toolbarScreen)
        check(toolbarEdge.minX >= toolbarScreen.minX+7.5 && toolbarEdge.maxX <= toolbarScreen.maxX-7.5,"Inline toolbar is clamped horizontally")
        let demo = Renderer.demo()
        check(demo.pixelSize == CGSize(width:1200,height:760),"Exact pixel dimensions")
        let mark = Mark(tool:.redact,points:[CGPoint(x:50,y:50),CGPoint(x:180,y:140)],color:.red,width:5)
        let rendered = Renderer.render(demo,marks:[mark])
        let bitmap = NSBitmapImageRep(data:rendered.png!)!
        let c = bitmap.colorAt(x:100,y:100)!.usingColorSpace(.deviceRGB)!
        check(c.redComponent < 0.15 && c.alphaComponent > 0.99,"Opaque redaction at correct top-left coordinates")
        let crop = Renderer.crop(rendered,rect:CGRect(x:50,y:50,width:130,height:90))
        check(crop.pixelSize == CGSize(width:130,height:90),"Crop pixel bounds")
        let cc = NSBitmapImageRep(data:crop.png!)!.colorAt(x:50,y:40)!.usingColorSpace(.deviceRGB)!
        check(cc.redComponent < 0.15,"Crop content matches selection")
        let backdrop = Renderer.render(demo,marks:[],backdrop:.mint,padding:64)
        check(backdrop.pixelSize == CGSize(width:1328,height:888),"Backdrop padding")
        func markerImage(_ size:CGSize,_ marker:CGRect) -> CGImage {
            let image = Renderer.bitmap(size:size) {
                NSColor(hex:0x203040).setFill(); NSBezierPath(rect:CGRect(origin:.zero,size:size)).fill()
                NSColor.red.setFill(); NSBezierPath(rect:marker).fill()
            }
            return image.cgImage(forProposedRect:nil,context:nil,hints:nil)!
        }
        func frozen(_ id:CGDirectDisplayID,_ frame:NSRect,_ cg:CGImage) -> FrozenFrame {
            FrozenFrame(displayID:id,frame:frame,image:NSImage(pixelImage:cg),cgImage:cg)
        }
        func isRed(_ image:NSImage?,_ x:Int,_ y:Int) -> Bool {
            guard let image,let rep = NSBitmapImageRep(data:image.png!),let c = rep.colorAt(x:x,y:y)?.usingColorSpace(.deviceRGB) else {return false}
            return c.redComponent > 0.7 && c.greenComponent < 0.3 && c.blueComponent < 0.3
        }
        let demoCG = demo.cgImage(forProposedRect:nil,context:nil,hints:nil)!
        let frozenLeft = FrozenFrame(displayID:1,frame:NSRect(x:0,y:0,width:600,height:380),image:demo,cgImage:demoCG)
        let frozenRight = FrozenFrame(displayID:2,frame:NSRect(x:600,y:0,width:600,height:380),image:demo,cgImage:demoCG)
        let frozenCrop = FrozenCapture.crop([frozenLeft],rect:NSRect(x:50,y:50,width:100,height:60))
        check(frozenCrop?.pixelSize == CGSize(width:200,height:120),"Frozen crop keeps native Retina pixels")
        let frozenAcross = FrozenCapture.crop([frozenLeft,frozenRight],rect:NSRect(x:550,y:100,width:100,height:100))
        check(frozenAcross?.pixelSize == CGSize(width:200,height:200),"Frozen crop composites across displays")
        let marker = Renderer.bitmap(size:CGSize(width:100,height:100)) {
            NSColor.red.setFill(); NSBezierPath(rect:CGRect(x:0,y:0,width:100,height:50)).fill()
            NSColor.blue.setFill(); NSBezierPath(rect:CGRect(x:0,y:50,width:100,height:50)).fill()
        }
        let markerFrame = FrozenFrame(displayID:1,frame:NSRect(x:0,y:0,width:50,height:50),image:marker,cgImage:marker.cgImage(forProposedRect:nil,context:nil,hints:nil)!)
        let bottomHalf = FrozenCapture.crop([markerFrame],rect:NSRect(x:0,y:0,width:50,height:25))!
        let bottomColor = NSBitmapImageRep(data:bottomHalf.png!)!.colorAt(x:10,y:10)!.usingColorSpace(.deviceRGB)!
        check(bottomColor.blueComponent > 0.5 && bottomColor.redComponent < 0.5,"Frozen crop maps NSScreen coordinates to image pixels")
        // Main 2x display: middle selection must crop the middle content at 3024x1964.
        let mainCG = markerImage(CGSize(width:3024,height:1964),CGRect(x:1500,y:1000,width:100,height:100))
        let mainImage = NSImage(pixelImage:mainCG)
        check(mainImage.pixelSize == CGSize(width:3024,height:1964),"Frozen NSImage keeps CG pixel size on Retina")
        let mainFrame = frozen(1,NSRect(x:0,y:0,width:1512,height:982),mainCG)
        let mainCrop = FrozenCapture.crop([mainFrame],rect:NSRect(x:750,y:432,width:100,height:100))
        check(mainCrop?.pixelSize == CGSize(width:200,height:200),"Main display crop is native 2x pixels")
        check(isRed(mainCrop,50,150),"Main display middle selection crops middle content")
        // Regression: NSImage(cgImage:size:) reports 2x pixelsWide on Retina; scale must use CGImage.
        let oneXCG = markerImage(CGSize(width:1512,height:982),CGRect(x:756,y:491,width:50,height:50))
        let oneXFrame = FrozenFrame(displayID:1,frame:NSRect(x:0,y:0,width:1512,height:982),image:NSImage(cgImage:oneXCG,size:NSSize(width:1512,height:982)),cgImage:oneXCG)
        check(oneXFrame.scale == 1,"Frozen scale follows CGImage pixels, not NSImage snapshot size")
        check(isRed(FrozenCapture.crop([oneXFrame],rect:NSRect(x:750,y:430,width:100,height:100)),20,50),"1x frozen frame keeps the selected region")
        // User layout: external 2x display left of and below main, top edge above main's top.
        let externalCG = markerImage(CGSize(width:6016,height:3384),CGRect(x:2000,y:1000,width:100,height:100))
        let externalFrame = frozen(3,NSRect(x:-3008,y:-669,width:3008,height:1692),externalCG)
        let externalCrop = FrozenCapture.crop([externalFrame],rect:NSRect(x:-2033,y:448,width:100,height:100))
        check(externalCrop?.pixelSize == CGSize(width:200,height:200),"External 2x display crop is native pixels")
        check(isRed(externalCrop,100,100),"External display below-left maps the selection correctly")
        let aboveFrame = frozen(2,NSRect(x:0,y:982,width:1512,height:982),mainCG)
        check(isRed(FrozenCapture.crop([aboveFrame],rect:NSRect(x:725,y:1389,width:100,height:100)),100,100),"Display above main maps the selection correctly")
        let joined = Renderer.stitch([demo,demo],overlap:60)!
        check(joined.pixelSize == CGSize(width:1200,height:1460),"Vertical stitch and overlap")
        let request = VNRecognizeTextRequest();request.recognitionLevel = .accurate;request.recognitionLanguages = ["en-US","zh-Hans"]
        do {try VNImageRequestHandler(cgImage:demo.cgImage(forProposedRect:nil,context:nil,hints:nil)!,options:[:]).perform([request]);let text = (request.results ?? []).compactMap {$0.topCandidates(1).first?.string}.joined(separator:" ");check(text.contains("Capture") || text.contains("QING"),"Rendered image orientation and local OCR")} catch {check(false,"OCR: \(error)")}
        let dir = URL(fileURLWithPath:ProcessInfo.processInfo.environment["QINGSHOT_TEST_OUTPUT"] ?? NSTemporaryDirectory()).appendingPathComponent("qingshot-validation",isDirectory:true)
        try? FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        try? demo.png?.write(to:dir.appendingPathComponent("demo.png"));try? backdrop.png?.write(to:dir.appendingPathComponent("backdrop.png"));try? rendered.png?.write(to:dir.appendingPathComponent("redacted.png"))
        print("Artifacts: \(dir.path)");exit(failures == 0 ? 0 : 1)
    }
}
