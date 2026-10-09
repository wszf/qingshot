import Foundation

enum LocalizationTests {
    static func run() {
        var failures = 0
        func check(_ ok:Bool,_ name:String) {print("\(ok ? "PASS" : "FAIL") \(name)");if !ok {failures += 1}}
        func table(_ language:String) -> [String:String] {
            let path = Localization.resources.path(forResource:"Localizable",ofType:"strings",inDirectory:nil,forLocalization:language)!
            let data = try! Data(contentsOf:URL(fileURLWithPath:path))
            return try! PropertyListSerialization.propertyList(from:data,format:nil) as! [String:String]
        }
        let en = table("en"), zh = table("zh-Hans")
        check(en.count >= 175 && Set(en.keys) == Set(zh.keys),"Matching and complete language tables (\(en.count) keys)")
        let regex = try! NSRegularExpression(pattern:"\\{\\d+\\}")
        func placeholders(_ text:String) -> [String] {let ns = text as NSString;return regex.matches(in:text,range:NSRange(location:0,length:ns.length)).map {ns.substring(with:$0.range)}.sorted()}
        check(en.allSatisfy {key,value in placeholders(key) == placeholders(value)},"English interpolation placeholders match")
        check(zh.allSatisfy {key,value in placeholders(key) == placeholders(value)},"Chinese interpolation placeholders match")
        check(Localization.text("窗口截图",language:"en") == "Capture Window","English lookup")
        check(Localization.text("窗口截图",language:"zh-Hans") == "窗口截图","Chinese lookup")
        check(Localization.text("已保存到 {0}",arguments:["capture {0}.png"],language:"en") == "Saved to capture {0}.png","Interpolation preserves placeholders inside filenames")
        check(Localization.languageCode(selection:"system",preferred:["zh-Hans-SG"]) == "zh-Hans","System Chinese fallback")
        check(Localization.languageCode(selection:"system",preferred:["fr-FR"]) == "en","Unsupported system language falls back to English")
        check(Localization.languageCode(selection:"en",preferred:["zh-Hans"]) == "en","Explicit language overrides system")
        check(en.values.allSatisfy {!$0.isEmpty},"No empty English translations")
        print("Localization bundle: \(Localization.resources.bundleURL.path)")
        exit(failures == 0 ? 0 : 1)
    }
}
