import ApplicationServices
import Foundation

final class HotKeyMonitor {
    private let onPress: () -> Void
    private let onRelease: () -> Void
    private let onEscape: () -> Bool
    private let onReturn: () -> Bool
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isPressed = false
    private var isEscapeCancelling = false
    private var isReturnSubmitting = false
    private var hotKey: HotKeySettings

    init(hotKey: HotKeySettings, onPress: @escaping () -> Void, onRelease: @escaping () -> Void, onEscape: @escaping () -> Bool, onReturn: @escaping () -> Bool) {
        self.hotKey = hotKey
        self.onPress = onPress
        self.onRelease = onRelease
        self.onEscape = onEscape
        self.onReturn = onReturn
    }

    func updateHotKey(_ hotKey: HotKeySettings) {
        self.hotKey = hotKey
        resetState()
        DebugLog.shared.info("hotkey updated: \(AppSettings.displayName(for: hotKey))")
    }

    func resetState() {
        isPressed = false
        isEscapeCancelling = false
        isReturnSubmitting = false
    }

    func start() -> Bool {
        if eventTap != nil {
            DebugLog.shared.info("hotkey monitor already started")
            return true
        }

        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        let refcon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { proxy, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<HotKeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                return monitor.handle(proxy: proxy, type: type, event: event)
            },
            userInfo: refcon
        ) else {
            return false
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        resetState()
        runLoopSource = nil
        eventTap = nil
    }

    private func handle(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            isPressed = false
            isEscapeCancelling = false
            isReturnSubmitting = false
            DebugLog.shared.warning("hotkey event tap disabled by system; resetting pressed state and re-enabling")
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        if keyCode == 53 {
            if type == .keyDown {
                if !isEscapeCancelling {
                    isEscapeCancelling = onEscape()
                }
                return isEscapeCancelling ? nil : Unmanaged.passUnretained(event)
            }

            if type == .keyUp, isEscapeCancelling {
                isEscapeCancelling = false
                return nil
            }
        }

        if keyCode == 36 {
            if type == .keyDown, onReturn() {
                isReturnSubmitting = true
                return nil
            }

            if type == .keyUp, isReturnSubmitting {
                isReturnSubmitting = false
                return nil
            }
        }

        if type == .keyUp, keyCode == hotKey.keyCode, isPressed {
            isPressed = false
            onRelease()
            return nil
        }

        let activeModifiers = Self.normalizedModifiers(event.flags)
        let isConfiguredHotKeyDown = type == .keyDown && keyCode == hotKey.keyCode && activeModifiers == hotKey.modifiers
        guard isConfiguredHotKeyDown else { return Unmanaged.passUnretained(event) }

        if !isPressed {
            isPressed = true
            onPress()
        }
        return nil
    }

    private static func normalizedModifiers(_ flags: CGEventFlags) -> CGEventFlags {
        var normalized = CGEventFlags()
        if flags.contains(.maskControl) { normalized.insert(.maskControl) }
        if flags.contains(.maskAlternate) { normalized.insert(.maskAlternate) }
        if flags.contains(.maskShift) { normalized.insert(.maskShift) }
        if flags.contains(.maskCommand) { normalized.insert(.maskCommand) }
        return normalized
    }
}
