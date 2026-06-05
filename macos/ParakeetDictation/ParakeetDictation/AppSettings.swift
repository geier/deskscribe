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

struct NativeONNXModelPreset: Equatable {
    let id: String
    let title: String
    let version: String
    let manifestURL: URL
    let recommendation: String

    var settings: ModelSettings {
        ModelSettings(repo: id, file: version)
    }
}

enum NativeONNXModelPresets {
    static let primeline = NativeONNXModelPreset(
        id: "parakeet-primeline-onnx",
        title: "DeskScribe PrimeLine ONNX",
        version: "v1",
        manifestURL: URL(string: "https://huggingface.co/geier/deskscribe-parakeet-primeline-onnx/resolve/main/parakeet-primeline-onnx-v1.manifest.json")!,
        recommendation: "Best default for German dictation and mixed DeskScribe testing. Choose this unless you specifically want an NVIDIA English model."
    )

    static let nvidiaTDTv3 = NativeONNXModelPreset(
        id: "nvidia-parakeet-tdt-0.6b-v3-onnx",
        title: "NVIDIA Parakeet TDT 0.6B v3 ONNX",
        version: "v1",
        manifestURL: URL(string: "https://huggingface.co/geier/deskscribe-nvidia-parakeet-tdt-0.6b-v3-onnx/resolve/main/nvidia-parakeet-tdt-0.6b-v3-onnx-v1.manifest.json")!,
        recommendation: "Use for current NVIDIA Parakeet English ASR. This is the preferred English option to compare against PrimeLine."
    )

    static let nvidiaTDTv2 = NativeONNXModelPreset(
        id: "nvidia-parakeet-tdt-0.6b-v2-onnx",
        title: "NVIDIA Parakeet TDT 0.6B v2 English ONNX",
        version: "v1",
        manifestURL: URL(string: "https://huggingface.co/geier/deskscribe-nvidia-parakeet-tdt-0.6b-v2-onnx/resolve/main/nvidia-parakeet-tdt-0.6b-v2-onnx-v1.manifest.json")!,
        recommendation: "Use for English fallback testing or comparison with the older NVIDIA TDT release. Prefer v3 for normal English use."
    )

    static let all = [primeline, nvidiaTDTv3, nvidiaTDTv2]
    static let defaultPreset = primeline

    static func preset(for model: ModelSettings) -> NativeONNXModelPreset {
        all.first { $0.settings == model } ?? defaultPreset
    }

    static func preset(titled title: String?) -> NativeONNXModelPreset? {
        all.first { $0.title == title }
    }
}

struct VocabularySettings: Equatable {
    var words: [String]
}

enum TriggerMode: String, CaseIterable {
    case toggle
    case hold

    var displayName: String {
        switch self {
        case .toggle: return "Press to Start/Stop"
        case .hold: return "Hold to Dictate"
        }
    }
}

enum AppSettings {
    static let defaultModel = NativeONNXModelPresets.defaultPreset.settings
    static let defaultHotKey = HotKeySettings(keyCode: 49, modifiers: .maskAlternate)
    static let defaultTriggerMode = TriggerMode.toggle
    static let defaultVocabulary = VocabularySettings(words: [])
    static let defaultRestorePasteboardAfterPaste = false

    private static let hotKeyKeyCodeKey = "hotKey.keyCode"
    private static let hotKeyModifiersKey = "hotKey.modifiers"
    private static let triggerModeKey = "trigger.mode.v2"
    private static let modelRepoKey = "model.repo"
    private static let modelFileKey = "model.file"
    private static let vocabularyWordsKey = "vocabulary.words"
    private static let restorePasteboardAfterPasteKey = "pasteboard.restoreAfterPaste"

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

    static var triggerMode: TriggerMode {
        get {
            guard let value = UserDefaults.standard.string(forKey: triggerModeKey),
                  let mode = TriggerMode(rawValue: value) else {
                return defaultTriggerMode
            }
            return mode
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: triggerModeKey)
        }
    }

    static var vocabulary: VocabularySettings {
        get {
            let words = UserDefaults.standard.stringArray(forKey: vocabularyWordsKey) ?? defaultVocabulary.words
            return VocabularySettings(words: normalizedVocabulary(words))
        }
        set {
            UserDefaults.standard.set(normalizedVocabulary(newValue.words), forKey: vocabularyWordsKey)
        }
    }

    static var restorePasteboardAfterPaste: Bool {
        get {
            if UserDefaults.standard.object(forKey: restorePasteboardAfterPasteKey) == nil {
                return defaultRestorePasteboardAfterPaste
            }
            return UserDefaults.standard.bool(forKey: restorePasteboardAfterPasteKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: restorePasteboardAfterPasteKey)
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

    static func normalizedVocabulary(_ words: [String]) -> [String] {
        var seen = Set<String>()
        var normalized: [String] = []

        for word in words {
            let value = word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            let key = value.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            normalized.append(value)
        }

        return normalized
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
