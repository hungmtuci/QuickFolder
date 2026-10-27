import Foundation
import AppKit
import Carbon
import Combine

enum ToggleShortcutPreset: String, CaseIterable {
    case cmdShiftD = "cmd_shift_d"
    case ctrlOptD = "ctrl_opt_d"
    case optSpace = "opt_space"

    var displayLabel: String {
        switch self {
        case .cmdShiftD: return "⌘ ⇧ D"
        case .ctrlOptD: return "⌃ ⌥ D"
        case .optSpace: return "⌥ Space"
        }
    }

    var compactLabel: String {
        switch self {
        case .cmdShiftD: return "⌘⇧D"
        case .ctrlOptD: return "⌃⌥D"
        case .optSpace: return "⌥Space"
        }
    }

    var keyCode: UInt32 {
        switch self {
        case .cmdShiftD, .ctrlOptD: return UInt32(kVK_ANSI_D)
        case .optSpace: return UInt32(kVK_Space)
        }
    }

    var carbonModifiers: UInt32 {
        switch self {
        case .cmdShiftD: return UInt32(cmdKey | shiftKey)
        case .ctrlOptD: return UInt32(controlKey | optionKey)
        case .optSpace: return UInt32(optionKey)
        }
    }
}

enum FinderJumpShortcutPreset: String, CaseIterable {
    case cmdShiftF = "cmd_shift_f"
    case optF = "opt_f"
    case ctrlOptF = "ctrl_opt_f"

    var displayLabel: String {
        switch self {
        case .cmdShiftF: return "⌘ ⇧ F"
        case .optF: return "⌥ F"
        case .ctrlOptF: return "⌃ ⌥ F"
        }
    }

    var compactLabel: String {
        switch self {
        case .cmdShiftF: return "⌘⇧F"
        case .optF: return "⌥F"
        case .ctrlOptF: return "⌃⌥F"
        }
    }

    var keyCode: UInt32 {
        UInt32(kVK_ANSI_F)
    }

    var carbonModifiers: UInt32 {
        switch self {
        case .cmdShiftF: return UInt32(cmdKey | shiftKey)
        case .optF: return UInt32(optionKey)
        case .ctrlOptF: return UInt32(controlKey | optionKey)
        }
    }
}

@MainActor
final class HotKeyManager: ObservableObject {
    static let shared = HotKeyManager()

    var onToggleFloatingPanel: (() -> Void)?
    var onJumpToFrontmostFinder: (() -> Void)?
    var onSelectQuickIndex: ((Int) -> Void)?

    @Published var togglePreset: ToggleShortcutPreset {
        didSet {
            UserDefaults.standard.set(togglePreset.rawValue, forKey: togglePresetKey)
            rebindToggleHotKey()
        }
    }

    @Published var finderJumpPreset: FinderJumpShortcutPreset {
        didSet {
            UserDefaults.standard.set(finderJumpPreset.rawValue, forKey: finderJumpPresetKey)
            syncFinderJumpHotKeyRegistration()
        }
    }

    /// When enabled (default `true`), `⌘⇧F` is ONLY intercepted while a Save/Open dialog (or QuickFolder panel) is active,
    /// so it never conflicts with "Find in Files" (`⌘⇧F`) in VS Code, Xcode, Antigravity, or browsers!
    @Published var onlyInterceptFinderJumpWhenSaveOpen: Bool {
        didSet {
            UserDefaults.standard.set(onlyInterceptFinderJumpWhenSaveOpen, forKey: contextAwareKey)
            syncFinderJumpHotKeyRegistration()
        }
    }

    private let togglePresetKey = "QuickFolder.ToggleShortcutPreset.v1"
    private let finderJumpPresetKey = "QuickFolder.FinderJumpShortcutPreset.v1"
    private let contextAwareKey = "QuickFolder.ContextAwareFinderShortcut.v1"

    private var toggleHotKeyRef: EventHotKeyRef?
    private var finderJumpHotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?
    private var cancellables = Set<AnyCancellable>()
    private var isStarted = false

    private init() {
        let savedToggle = UserDefaults.standard.string(forKey: togglePresetKey) ?? ToggleShortcutPreset.cmdShiftD.rawValue
        self.togglePreset = ToggleShortcutPreset(rawValue: savedToggle) ?? .cmdShiftD

        let savedJump = UserDefaults.standard.string(forKey: finderJumpPresetKey) ?? FinderJumpShortcutPreset.cmdShiftF.rawValue
        self.finderJumpPreset = FinderJumpShortcutPreset(rawValue: savedJump) ?? .cmdShiftF

        if UserDefaults.standard.object(forKey: contextAwareKey) == nil {
            self.onlyInterceptFinderJumpWhenSaveOpen = true
            UserDefaults.standard.set(true, forKey: contextAwareKey)
        } else {
            self.onlyInterceptFinderJumpWhenSaveOpen = UserDefaults.standard.bool(forKey: contextAwareKey)
        }
    }

    func registerHotKeys() {
        guard !isStarted else { return }
        isStarted = true

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

        rebindToggleHotKey()
        syncFinderJumpHotKeyRegistration()

        // Dynamically register/unregister Finder-Jump hotkey whenever Save/Open dialog state changes
        SavePanelDetector.shared.$activePanel
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.syncFinderJumpHotKeyRegistration()
            }
            .store(in: &cancellables)

        // Monitor Option+1..9 only when the floating panel is visible
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

    func notifyPanelVisibilityChanged() {
        syncFinderJumpHotKeyRegistration()
    }

    private func rebindToggleHotKey() {
        guard isStarted else { return }
        if let ref = toggleHotKeyRef {
            UnregisterEventHotKey(ref)
            toggleHotKeyRef = nil
        }
        let toggleID = EventHotKeyID(signature: OSType(0x51464C44), id: 1) // 'QFLD'
        RegisterEventHotKey(
            togglePreset.keyCode,
            togglePreset.carbonModifiers,
            toggleID,
            GetApplicationEventTarget(),
            0,
            &toggleHotKeyRef
        )
    }

    func syncFinderJumpHotKeyRegistration() {
        guard isStarted else { return }
        let shouldBeRegistered: Bool
        if onlyInterceptFinderJumpWhenSaveOpen {
            shouldBeRegistered = (SavePanelDetector.shared.activePanel != nil) || FloatingPanelController.shared.isPanelVisible
        } else {
            shouldBeRegistered = true
        }

        if shouldBeRegistered {
            // Re-register cleanly if not registered (or if preset changed)
            if let ref = finderJumpHotKeyRef {
                UnregisterEventHotKey(ref)
                finderJumpHotKeyRef = nil
            }
            let finderJumpID = EventHotKeyID(signature: OSType(0x51464C44), id: 2)
            RegisterEventHotKey(
                finderJumpPreset.keyCode,
                finderJumpPreset.carbonModifiers,
                finderJumpID,
                GetApplicationEventTarget(),
                0,
                &finderJumpHotKeyRef
            )
        } else {
            if let ref = finderJumpHotKeyRef {
                UnregisterEventHotKey(ref)
                finderJumpHotKeyRef = nil
            }
        }
    }

    @discardableResult
    private func handleOptionNumberEvent(_ event: NSEvent) -> Bool {
        guard FloatingPanelController.shared.isPanelVisible else { return false }
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
