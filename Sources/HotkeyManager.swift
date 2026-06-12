import AppKit
import Carbon.HIToolbox

/// Registers global hotkeys via Carbon `RegisterEventHotKey` (intercepting, no
/// Accessibility permission, available immediately after wake). Two chords are
/// supported, distinguished by their `EventHotKeyID.id`:
///
/// - `id: 1` → the capture box (`onHotkey`)
/// - `id: 2` → voice capture toggle (`onVoiceHotkey`)
///
/// A single application event handler dispatches both; it reads the fired
/// hotkey's id out of the Carbon event and routes accordingly.
final class HotkeyManager {
    var onHotkey: (() -> Void)?
    var onVoiceHotkey: (() -> Void)?

    private var captureRef: EventHotKeyRef?
    private var voiceRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    private static let signature = OSType(0x73746173)   // 'stas'
    private static let captureID: UInt32 = 1
    private static let voiceID: UInt32 = 2

    init() { installHandler() }

    deinit {
        unregisterAll()
        if let h = handlerRef { RemoveEventHandler(h) }
    }

    private func installHandler() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind:  UInt32(kEventHotKeyPressed))
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(),
                            { (_, event, userData) -> OSStatus in
                                guard let userData = userData else { return noErr }
                                let mgr = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                                var hkID = EventHotKeyID()
                                if let event = event,
                                   GetEventParameter(event,
                                                     EventParamName(kEventParamDirectObject),
                                                     EventParamType(typeEventHotKeyID),
                                                     nil,
                                                     MemoryLayout<EventHotKeyID>.size,
                                                     nil,
                                                     &hkID) == noErr {
                                    mgr.dispatch(id: hkID.id)
                                }
                                return noErr
                            },
                            1, &spec, ctx, &handlerRef)
    }

    private func dispatch(id: UInt32) {
        switch id {
        case Self.captureID: onHotkey?()
        case Self.voiceID:   onVoiceHotkey?()
        default: break
        }
    }

    // MARK: - Capture hotkey (id 1)

    func registerCapture(keyCode: UInt32, cocoaModifiers: NSEvent.ModifierFlags) {
        unregisterCapture()
        let id = EventHotKeyID(signature: Self.signature, id: Self.captureID)
        let mods = Self.carbonModifiers(from: cocoaModifiers)
        RegisterEventHotKey(keyCode, mods, id, GetApplicationEventTarget(), 0, &captureRef)
    }

    func unregisterCapture() {
        if let ref = captureRef {
            UnregisterEventHotKey(ref)
            captureRef = nil
        }
    }

    // MARK: - Voice hotkey (id 2)

    func registerVoice(keyCode: UInt32, cocoaModifiers: NSEvent.ModifierFlags) {
        unregisterVoice()
        let id = EventHotKeyID(signature: Self.signature, id: Self.voiceID)
        let mods = Self.carbonModifiers(from: cocoaModifiers)
        RegisterEventHotKey(keyCode, mods, id, GetApplicationEventTarget(), 0, &voiceRef)
    }

    func unregisterVoice() {
        if let ref = voiceRef {
            UnregisterEventHotKey(ref)
            voiceRef = nil
        }
    }

    func unregisterAll() {
        unregisterCapture()
        unregisterVoice()
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.option)  { m |= UInt32(optionKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.shift)   { m |= UInt32(shiftKey) }
        return m
    }
}
