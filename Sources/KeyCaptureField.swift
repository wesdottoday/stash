import AppKit
import Carbon.HIToolbox

final class KeyCaptureField: NSTextField {
    var onCapture: ((UInt32, NSEvent.ModifierFlags) -> Void)?
    var onWillBeginCapture: (() -> Void)?
    var onDidEndCapture: (() -> Void)?

    private(set) var keyCode: UInt32 = UInt32(Preferences.defaultHotkeyKeyCode)
    private(set) var modifiers: NSEvent.ModifierFlags = NSEvent.ModifierFlags(rawValue: Preferences.defaultHotkeyModifiers)

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        isEditable = false
        isSelectable = false
        isBezeled = true
        bezelStyle = .roundedBezel
        alignment = .center
        usesSingleLineMode = true
        focusRingType = .default
        refreshDisplay()
    }

    func setBinding(keyCode: UInt32, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        refreshDisplay()
    }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok {
            stringValue = "Press a key…"
            onWillBeginCapture?()
        }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        refreshDisplay()
        onDidEndCapture?()
        return super.resignFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        // Modifier-only keys are filtered out by the OS keyDown.
        let mods: NSEvent.ModifierFlags = event.modifierFlags.intersection(
            [.command, .option, .control, .shift]
        )
        guard !mods.isEmpty else {
            // Just a plain key — refuse and keep editing.
            NSSound.beep()
            return
        }
        keyCode = UInt32(event.keyCode)
        modifiers = mods
        refreshDisplay()
        onCapture?(keyCode, modifiers)
        window?.makeFirstResponder(nil)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self {
            keyDown(with: event)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    private func refreshDisplay() {
        stringValue = KeyCaptureField.describe(keyCode: keyCode, modifiers: modifiers)
    }

    static func describe(keyCode: UInt32, modifiers: NSEvent.ModifierFlags) -> String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("⌃") }
        if modifiers.contains(.option)  { parts.append("⌥") }
        if modifiers.contains(.shift)   { parts.append("⇧") }
        if modifiers.contains(.command) { parts.append("⌘") }
        parts.append(keyName(for: keyCode))
        return parts.joined()
    }

    static func keyName(for keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case kVK_ANSI_A: return "A"; case kVK_ANSI_B: return "B"
        case kVK_ANSI_C: return "C"; case kVK_ANSI_D: return "D"
        case kVK_ANSI_E: return "E"; case kVK_ANSI_F: return "F"
        case kVK_ANSI_G: return "G"; case kVK_ANSI_H: return "H"
        case kVK_ANSI_I: return "I"; case kVK_ANSI_J: return "J"
        case kVK_ANSI_K: return "K"; case kVK_ANSI_L: return "L"
        case kVK_ANSI_M: return "M"; case kVK_ANSI_N: return "N"
        case kVK_ANSI_O: return "O"; case kVK_ANSI_P: return "P"
        case kVK_ANSI_Q: return "Q"; case kVK_ANSI_R: return "R"
        case kVK_ANSI_S: return "S"; case kVK_ANSI_T: return "T"
        case kVK_ANSI_U: return "U"; case kVK_ANSI_V: return "V"
        case kVK_ANSI_W: return "W"; case kVK_ANSI_X: return "X"
        case kVK_ANSI_Y: return "Y"; case kVK_ANSI_Z: return "Z"
        case kVK_ANSI_0: return "0"; case kVK_ANSI_1: return "1"
        case kVK_ANSI_2: return "2"; case kVK_ANSI_3: return "3"
        case kVK_ANSI_4: return "4"; case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"; case kVK_ANSI_7: return "7"
        case kVK_ANSI_8: return "8"; case kVK_ANSI_9: return "9"
        case kVK_Space:    return "Space"
        case kVK_Return:   return "↩"
        case kVK_Tab:      return "⇥"
        case kVK_Escape:   return "⎋"
        case kVK_Delete:   return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_LeftArrow:     return "←"
        case kVK_RightArrow:    return "→"
        case kVK_UpArrow:       return "↑"
        case kVK_DownArrow:     return "↓"
        case kVK_ANSI_Slash:    return "/"
        case kVK_ANSI_Period:   return "."
        case kVK_ANSI_Comma:    return ","
        case kVK_ANSI_Semicolon:return ";"
        case kVK_ANSI_Quote:    return "'"
        case kVK_ANSI_LeftBracket:  return "["
        case kVK_ANSI_RightBracket: return "]"
        case kVK_ANSI_Backslash:    return "\\"
        case kVK_ANSI_Equal:    return "="
        case kVK_ANSI_Minus:    return "-"
        case kVK_ANSI_Grave:    return "`"
        case kVK_F1:  return "F1";  case kVK_F2:  return "F2"
        case kVK_F3:  return "F3";  case kVK_F4:  return "F4"
        case kVK_F5:  return "F5";  case kVK_F6:  return "F6"
        case kVK_F7:  return "F7";  case kVK_F8:  return "F8"
        case kVK_F9:  return "F9";  case kVK_F10: return "F10"
        case kVK_F11: return "F11"; case kVK_F12: return "F12"
        default: return "Key \(keyCode)"
        }
    }
}
