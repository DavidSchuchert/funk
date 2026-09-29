import Carbon.HIToolbox

/// Auswahl an Tastenkürzeln für die Sprechtaste.
/// F13 bis F19 sind ideal: Die gibt es auf vielen Tastaturen, und sie kollidieren mit nichts.
enum HotKeyChoice: String, CaseIterable, Identifiable {
    case off, f13, f14, f15, f16, f17, f18, f19, ctrlOptionSpace

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: "Aus"
        case .ctrlOptionSpace: "⌃⌥ Leertaste"
        default: rawValue.uppercased()
        }
    }

    var keyCode: UInt32? {
        switch self {
        case .off: nil
        case .f13: UInt32(kVK_F13)
        case .f14: UInt32(kVK_F14)
        case .f15: UInt32(kVK_F15)
        case .f16: UInt32(kVK_F16)
        case .f17: UInt32(kVK_F17)
        case .f18: UInt32(kVK_F18)
        case .f19: UInt32(kVK_F19)
        case .ctrlOptionSpace: UInt32(kVK_Space)
        }
    }

    var modifiers: UInt32 {
        self == .ctrlOptionSpace ? UInt32(controlKey | optionKey) : 0
    }
}

/// Globales Push-to-Talk-Kürzel über die Carbon-Hotkey-API.
///
/// Warum Carbon: Sie meldet Drücken UND Loslassen, und die App braucht dafür keine
/// Bedienungshilfen-Berechtigung. Ein globaler NSEvent-Monitor bräuchte die und würde
/// dabei jede Taste im System mitlesen.
final class HotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    var onChange: ((Bool) -> Void)?

    init() {
        var types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            let hotKey = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
            hotKey.onChange?(GetEventKind(event) == UInt32(kEventHotKeyPressed))
            return noErr
        }, types.count, &types, me, &handlerRef)
    }

    deinit {
        unregister()
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }

    func register(_ choice: HotKeyChoice) {
        unregister()
        guard let code = choice.keyCode else { return }
        let id = EventHotKeyID(signature: OSType(0x46554E4B), id: 1)   // "FUNK"
        let err = RegisterEventHotKey(code, choice.modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
        if err != noErr { warn("Tastenkürzel \(choice.label) nicht registrierbar (\(err)), evtl. schon belegt") }
    }

    private func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        onChange?(false)          // falls die Taste beim Umstellen gerade gehalten wurde
    }
}
