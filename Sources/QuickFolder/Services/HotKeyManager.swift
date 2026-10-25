import Foundation
import AppKit
import Carbon

@MainActor
final class HotKeyManager {
    static let shared = HotKeyManager()

    var onToggleFloatingPanel: (() -> Void)?
    var onJumpToFrontmostFinder: (() -> Void)?
    var onSelectQuickIndex: ((Int) -> Void)?

    private var toggleHotKeyRef: EventHotKeyRef?
    private var finderJumpHotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?

    private init() {}

    func registerHotKeys() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let handler: EventHandlerUPP = { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard status == noErr else { return status }

            let id = hotKeyID.id
            Task { @MainActor in
                switch id {
                case 1:
                    HotKeyManager.shared.onToggleFloatingPanel?()
                case 2:
                    HotKeyManager.shared.onJumpToFrontmostFinder?()
                default:
                    break
                }
            }
            return noErr
        }

        InstallEventHandler(
            GetApplicationEventTarget(),
            handler,
            1,
            &eventType,
            nil,
            &eventHandlerRef
        )

        // HotKey 1: Cmd + Shift + D (keyCode 2 = 'D') -> Toggle QuickFolder Panel
        let toggleID = EventHotKeyID(signature: OSType(0x51464C44), id: 1) // 'QFLD'
        RegisterEventHotKey(
            UInt32(kVK_ANSI_D),
            UInt32(cmdKey | shiftKey),
            toggleID,
            GetApplicationEventTarget(),
            0,
            &toggleHotKeyRef
        )

        // HotKey 2: Cmd + Shift + F (keyCode 3 = 'F') -> Instant Jump to Frontmost Finder Window
        let finderJumpID = EventHotKeyID(signature: OSType(0x51464C44), id: 2)
        RegisterEventHotKey(
            UInt32(kVK_ANSI_F),
            UInt32(cmdKey | shiftKey),
            finderJumpID,
            GetApplicationEventTarget(),
            0,
            &finderJumpHotKeyRef
        )

        // Monitor Option+1..9 when the floating panel is visible
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Task { @MainActor in
                self?.handleOptionNumberEvent(event)
            }
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if let self = self, self.handleOptionNumberEvent(event) {
                return nil
            }
            return event
        }
    }

    @discardableResult
    private func handleOptionNumberEvent(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == [.option] else { return false }

        let numberKeyCodes: [UInt16: Int] = [
            UInt16(kVK_ANSI_1): 0,
            UInt16(kVK_ANSI_2): 1,
            UInt16(kVK_ANSI_3): 2,
            UInt16(kVK_ANSI_4): 3,
            UInt16(kVK_ANSI_5): 4,
            UInt16(kVK_ANSI_6): 5,
            UInt16(kVK_ANSI_7): 6,
            UInt16(kVK_ANSI_8): 7,
            UInt16(kVK_ANSI_9): 8
        ]

        if let index = numberKeyCodes[event.keyCode] {
            onSelectQuickIndex?(index)
            return true
        }
        return false
    }
}
