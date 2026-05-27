import AppKit
import Carbon.HIToolbox

final class HotkeyManager {
    var onHotkey: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    init() { installHandler() }

    deinit {
        unregister()
        if let h = handlerRef { RemoveEventHandler(h) }
    }

    private func installHandler() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind:  UInt32(kEventHotKeyPressed))
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(),
                            { (_, _, userData) -> OSStatus in
                                guard let userData = userData else { return noErr }
                                let mgr = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                                mgr.onHotkey?()
                                return noErr
                            },
                            1, &spec, ctx, &handlerRef)
    }

    func register(keyCode: UInt32, cocoaModifiers: NSEvent.ModifierFlags) {
        unregister()
        var id = EventHotKeyID(signature: OSType(0x73746173), id: 1) // 'stas'
        let mods = Self.carbonModifiers(from: cocoaModifiers)
        RegisterEventHotKey(keyCode, mods, id, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
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
