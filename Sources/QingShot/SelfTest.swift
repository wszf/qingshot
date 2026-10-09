import AppKit
import Vision

enum SelfTest {
    static func run() {
        var failures = 0
        func check(_ condition:Bool,_ label:String) {print("\(condition ? "PASS" : "FAIL") \(label)");if !condition {failures += 1}}
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
