import ApplicationServices
import Foundation

final class HotKeyMonitor {
    private let onPress: () -> Void
    private let onRelease: () -> Void
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isPressed = false
    private var hotKey: HotKeySettings

    init(hotKey: HotKeySettings, onPress: @escaping () -> Void, onRelease: @escaping () -> Void) {
        self.hotKey = hotKey
        self.onPress = onPress
        self.onRelease = onRelease
    }

    func updateHotKey(_ hotKey: HotKeySettings) {
        self.hotKey = hotKey
        isPressed = false
        DebugLog.shared.info("hotkey updated: \(AppSettings.displayName(for: hotKey))")
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
        runLoopSource = nil
        eventTap = nil
    }

    private func handle(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let activeModifiers = event.flags.rawValue & hotKey.modifiers.rawValue
        let isConfiguredHotKey = keyCode == hotKey.keyCode && activeModifiers == hotKey.modifiers.rawValue
        guard isConfiguredHotKey else { return Unmanaged.passUnretained(event) }

        if type == .keyDown {
            if !isPressed {
                isPressed = true
                onPress()
            }
            return nil
        }

        if type == .keyUp {
            if isPressed {
                isPressed = false
                onRelease()
            }
            return nil
        }

        return Unmanaged.passUnretained(event)
    }
}
