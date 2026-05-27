import AppKit
import Carbon.HIToolbox

/// A click-to-focus field that captures a single key combination. Unlike
/// NSTextField it isn't backed by a field editor, so mouseDown reliably
/// makes it first responder and keyDown reaches us directly.
final class KeyCaptureField: NSControl {
    var onCapture: ((UInt32, NSEvent.ModifierFlags) -> Void)?
    var onWillBeginCapture: (() -> Void)?
    var onDidEndCapture: (() -> Void)?

    private(set) var keyCode: UInt32 = UInt32(Preferences.defaultHotkeyKeyCode)
    private(set) var modifiers: NSEvent.ModifierFlags = NSEvent.ModifierFlags(rawValue: Preferences.defaultHotkeyModifiers)

    private var isCapturing = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        focusRingType = .default
    }
    required init?(coder: NSCoder) { nil }

    func setBinding(keyCode: UInt32, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        needsDisplay = true
    }

    // MARK: - Responder behaviour --------------------------------------------

    override var acceptsFirstResponder: Bool { isEnabled }
    override var canBecomeKeyView: Bool { isEnabled }
    override var needsPanelToBecomeKey: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 160, height: 22)
    }

    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        isCapturing = true
        needsDisplay = true
        onWillBeginCapture?()
        return true
    }

    override func resignFirstResponder() -> Bool {
        isCapturing = false
        needsDisplay = true
        onDidEndCapture?()
        return super.resignFirstResponder()
    }

    override func mouseDown(with event: NSEvent) {
        if !isCapturing { window?.makeFirstResponder(self) }
    }

    // MARK: - Key handling ----------------------------------------------------

    override func keyDown(with event: NSEvent) {
        captureChord(from: event)
    }

    /// Cmd-modified events normally route through `performKeyEquivalent` and
    /// would otherwise be consumed by the window's default chain. Intercept
    /// them while we're capturing so the user can bind chords containing Cmd.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isCapturing, window?.firstResponder === self else {
            return super.performKeyEquivalent(with: event)
        }
        captureChord(from: event)
        return true
    }

    private func captureChord(from event: NSEvent) {
        // Pressing just Esc cancels capture without changing the binding.
        if event.keyCode == UInt16(kVK_Escape) {
            isCapturing = false
            needsDisplay = true
            window?.makeFirstResponder(nil)
            return
        }
        let mods = event.modifierFlags.intersection(
            [.command, .option, .control, .shift]
        )
        guard !mods.isEmpty else {
            NSSound.beep()
            return
        }
        keyCode = UInt32(event.keyCode)
        modifiers = mods
        isCapturing = false
        needsDisplay = true
        onCapture?(keyCode, modifiers)
        window?.makeFirstResponder(nil)
    }

    // MARK: - Drawing ---------------------------------------------------------

    override func draw(_ dirtyRect: NSRect) {
        let bezel = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: bezel, xRadius: 4, yRadius: 4)
        NSColor.textBackgroundColor.setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()

        let text = isCapturing
            ? "Press a key…"
            : KeyCaptureField.describe(keyCode: keyCode, modifiers: modifiers)
        let color: NSColor = isCapturing ? .tertiaryLabelColor : .labelColor
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: color
        ]
        let attr = NSAttributedString(string: text, attributes: attrs)
        let size = attr.size()
        let textRect = NSRect(
            x: (bounds.width - size.width) / 2,
            y: (bounds.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
        attr.draw(in: textRect)
    }

    override func drawFocusRingMask() {
        let bezel = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: bezel, xRadius: 4, yRadius: 4)
        path.fill()
    }

    override var focusRingMaskBounds: NSRect { bounds }

    // MARK: - Description -----------------------------------------------------

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
