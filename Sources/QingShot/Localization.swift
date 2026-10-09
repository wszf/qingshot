import Foundation
import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable {
    case system, english = "en", simplifiedChinese = "zh-Hans"
    var id: String {rawValue}
    var title: String {
        switch self {case .system: return L("跟随系统"); case .english: return "English"; case .simplifiedChinese: return "简体中文"}
    }
}
final class LanguageStore: ObservableObject {
    static let shared = LanguageStore()
    @Published var selection: AppLanguage {
        didSet {UserDefaults.standard.set(selection.rawValue,forKey:"appLanguage")}
    }
    private init() {selection = AppLanguage(rawValue:UserDefaults.standard.string(forKey:"appLanguage") ?? "system") ?? .system}
}
enum Localization {
    static let resources: Bundle = {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("QingShot_QingShot.bundle"),let bundle = Bundle(url:url) {return bundle}
        return Bundle.module
    }()
    static func languageCode(selection: String? = nil, preferred: [String] = Locale.preferredLanguages) -> String {
        let requested = selection ?? UserDefaults.standard.string(forKey:"appLanguage") ?? "system"
        if requested == "en" || requested == "zh-Hans" {return requested}
        return preferred.first?.hasPrefix("zh") == true ? "zh-Hans" : "en"
    }
    private static let tables: [String:[String:String]] = {
        var result: [String:[String:String]] = [:]
        for code in ["en", "zh-Hans"] {
            guard let url = resources.url(forResource:"Localizable",withExtension:"strings",subdirectory:nil,localization:code),
                  let data = try? Data(contentsOf:url),
                  let table = (try? PropertyListSerialization.propertyList(from:data,format:nil)) as? [String:String] else {continue}
            result[code] = table
        }
        return result
    }()
    static func text(_ key:String, arguments:[String] = [], language:String? = nil) -> String {
        let code = language ?? languageCode()
        let format = tables[code]?[key] ?? tables["en"]?[key] ?? key
        // Single pass: a filename containing {0} must not be interpreted as a second placeholder.
        let regex = try! NSRegularExpression(pattern:"\\{(\\d+)\\}")
        let source = format as NSString
        var result = "", offset = 0
        for match in regex.matches(in:format,range:NSRange(location:0,length:source.length)) {
            result += source.substring(with:NSRange(location:offset,length:match.range.location-offset))
            let index = Int(source.substring(with:match.range(at:1)))!
            result += arguments.indices.contains(index) ? arguments[index] : source.substring(with:match.range)
            offset = NSMaxRange(match.range)
        }
        return result + source.substring(from:offset)
    }
}
func L(_ key:String,_ arguments:String...) -> String {Localization.text(key,arguments:arguments)}
