import ApplicationServices
import AppKit
import Foundation

struct HotKeySettings: Equatable {
    var keyCode: CGKeyCode
    var modifiers: CGEventFlags
}

struct ModelSettings: Equatable {
    var repo: String
    var file: String
}

enum AppSettings {
    static let defaultModel = ModelSettings(repo: "primeline/parakeet-primeline", file: "2_95_WER.nemo")
    static let defaultHotKey = HotKeySettings(keyCode: 49, modifiers: .maskAlternate)

    private static let hotKeyKeyCodeKey = "hotKey.keyCode"
    private static let hotKeyModifiersKey = "hotKey.modifiers"
    private static let modelRepoKey = "model.repo"
    private static let modelFileKey = "model.file"

    static var hotKey: HotKeySettings {
        get {
            let storedKeyCode = UserDefaults.standard.object(forKey: hotKeyKeyCodeKey) as? Int
            let storedModifiers = UserDefaults.standard.object(forKey: hotKeyModifiersKey) as? NSNumber
            return HotKeySettings(
                keyCode: CGKeyCode(storedKeyCode ?? Int(defaultHotKey.keyCode)),
                modifiers: CGEventFlags(rawValue: storedModifiers?.uint64Value ?? defaultHotKey.modifiers.rawValue)
            )
        }
        set {
            UserDefaults.standard.set(Int(newValue.keyCode), forKey: hotKeyKeyCodeKey)
            UserDefaults.standard.set(newValue.modifiers.rawValue, forKey: hotKeyModifiersKey)
        }
    }

    static var model: ModelSettings {
        get {
            ModelSettings(
                repo: UserDefaults.standard.string(forKey: modelRepoKey) ?? defaultModel.repo,
                file: UserDefaults.standard.string(forKey: modelFileKey) ?? defaultModel.file
            )
        }
        set {
            UserDefaults.standard.set(newValue.repo, forKey: modelRepoKey)
            UserDefaults.standard.set(newValue.file, forKey: modelFileKey)
        }
    }

    static func displayName(for hotKey: HotKeySettings) -> String {
        var parts: [String] = []
        if hotKey.modifiers.contains(.maskControl) { parts.append("Control") }
        if hotKey.modifiers.contains(.maskAlternate) { parts.append("Option") }
        if hotKey.modifiers.contains(.maskShift) { parts.append("Shift") }
        if hotKey.modifiers.contains(.maskCommand) { parts.append("Command") }
        parts.append(keyName(for: hotKey.keyCode))
        return parts.joined(separator: "+")
    }

    static func modifiers(from event: NSEvent) -> CGEventFlags {
        var flags = CGEventFlags()
        if event.modifierFlags.contains(.control) { flags.insert(.maskControl) }
        if event.modifierFlags.contains(.option) { flags.insert(.maskAlternate) }
        if event.modifierFlags.contains(.shift) { flags.insert(.maskShift) }
        if event.modifierFlags.contains(.command) { flags.insert(.maskCommand) }
        return flags
    }

    private static func keyName(for keyCode: CGKeyCode) -> String {
        switch keyCode {
        case 49: return "Space"
        case 36: return "Return"
        case 53: return "Escape"
        case 48: return "Tab"
        case 51: return "Delete"
        case 123: return "Left"
        case 124: return "Right"
        case 125: return "Down"
        case 126: return "Up"
        default: return "Key \(keyCode)"
        }
    }
}
