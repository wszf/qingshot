import AppKit
import SwiftUI

enum AppAppearance:String, CaseIterable, Identifiable {
    case system, light, dark
    var id:String {rawValue}
    var title:String {
        switch self {
        case .system: return L("跟随系统")
        case .light: return L("浅色")
        case .dark: return L("深色")
        }
    }
    var appearance:NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named:.aqua)
        case .dark: return NSAppearance(named:.darkAqua)
        }
    }
    static let defaultsKey = "appearanceMode"
    static func stored(in defaults:UserDefaults = .standard) -> AppAppearance {
        AppAppearance(rawValue:defaults.string(forKey:defaultsKey) ?? "") ?? .system
    }
}

@MainActor final class AppearanceStore:ObservableObject {
    static let shared = AppearanceStore()
    private let defaults:UserDefaults
    @Published var selection:AppAppearance {
        didSet {
            defaults.set(selection.rawValue,forKey:AppAppearance.defaultsKey)
            apply()
        }
    }

    private init(defaults:UserDefaults = .standard) {
        self.defaults = defaults
        self.selection = AppAppearance.stored(in:defaults)
        apply()
    }

    func apply() {NSApp.appearance = selection.appearance}
}

extension NSColor {
    static func dynamicColor(light:NSColor,dark:NSColor) -> NSColor {
        NSColor(name:NSColor.Name("QingShotDynamic-\(UUID().uuidString)"),dynamicProvider:{appearance in
            appearance.bestMatch(from:[.darkAqua,.aqua]) == .darkAqua ? dark : light
        })
    }
    static func dynamicColor(lightHex:UInt32,darkHex:UInt32) -> NSColor {
        dynamicColor(light:NSColor(hex:lightHex),dark:NSColor(hex:darkHex))
    }
}

enum Theme {
    static let accent = Color(nsColor:NSColor.dynamicColor(lightHex:0x337A64,darkHex:0x70D3AF))
    static let window = Color(nsColor:NSColor.dynamicColor(lightHex:0xFFFFFF,darkHex:0x1B211E))
    static let sidebar = Color(nsColor:NSColor.dynamicColor(lightHex:0xF2F5F1,darkHex:0x191F1C))
    static let canvas = Color(nsColor:NSColor.dynamicColor(lightHex:0xE8ECE8,darkHex:0x111614))
    static let welcome = Color(nsColor:NSColor.dynamicColor(lightHex:0xFAFBF8,darkHex:0x151A17))
    static let panel = Color(nsColor:NSColor.dynamicColor(lightHex:0xFAFBF8,darkHex:0x171D19))
    static let settings = Color(nsColor:NSColor.dynamicColor(lightHex:0xF6F8F5,darkHex:0x151A17))
    static let card = Color(nsColor:NSColor.dynamicColor(lightHex:0xFFFFFF,darkHex:0x232A26))
    static let thumb = Color(nsColor:NSColor.dynamicColor(lightHex:0xFFFFFF,darkHex:0x2A322D))
    static let title = Color(nsColor:NSColor.dynamicColor(lightHex:0x203B30,darkHex:0xE6F2EB))
    static let toolbar = Color(nsColor:NSColor.dynamicColor(lightHex:0xFDFDFC,darkHex:0x252C28))
    static let overlay = Color(nsColor:NSColor.dynamicColor(lightHex:0xFDFDFC,darkHex:0x202622))
    static let chip = Color(nsColor:NSColor.dynamicColor(lightHex:0x000000,darkHex:0xFFFFFF)).opacity(0.045)
    static let stroke = Color(nsColor:NSColor.dynamicColor(lightHex:0x000000,darkHex:0xFFFFFF)).opacity(0.14)
    static let shadow = Color(nsColor:NSColor.dynamicColor(lightHex:0x000000,darkHex:0x000000)).opacity(0.22)
}
