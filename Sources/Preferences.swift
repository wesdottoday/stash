import AppKit
import ServiceManagement

final class Preferences {
    static let shared = Preferences()

    private let defaults = UserDefaults.standard

    enum Keys {
        static let destinationFolder    = "destinationFolder"
        static let hotkeyKeyCode        = "hotkeyKeyCode"
        static let hotkeyModifiers      = "hotkeyModifiers"
        static let voiceHotkeyKeyCode   = "voiceHotkeyKeyCode"
        static let voiceHotkeyModifiers = "voiceHotkeyModifiers"
        static let confirmationEnabled  = "confirmationEnabled"
        static let confirmationDuration = "confirmationDuration"
        static let imageNormalization   = "imageNormalization"
        static let menuBarEnabled       = "menuBarEnabled"
        static let windowOriginX        = "windowOriginX"
        static let windowOriginY        = "windowOriginY"
        static let windowPositionSet    = "windowPositionSet"
        static let hasLaunchedBefore    = "hasLaunchedBefore"
        static let relayBaseURL         = "relayBaseURL"
    }

    static let defaultHotkeyKeyCode: Int = 44                                // forward slash
    static let defaultHotkeyModifiers: UInt = NSEvent.ModifierFlags([.control, .option, .command]).rawValue

    static let defaultVoiceHotkeyKeyCode: Int = 9                            // V (kVK_ANSI_V)
    static let defaultVoiceHotkeyModifiers: UInt = NSEvent.ModifierFlags([.control, .option, .command]).rawValue

    private init() {
        defaults.register(defaults: [
            Keys.destinationFolder:    (NSString(string: "~/_inbox").expandingTildeInPath),
            Keys.hotkeyKeyCode:        Preferences.defaultHotkeyKeyCode,
            Keys.hotkeyModifiers:      Int(Preferences.defaultHotkeyModifiers),
            Keys.voiceHotkeyKeyCode:   Preferences.defaultVoiceHotkeyKeyCode,
            Keys.voiceHotkeyModifiers: Int(Preferences.defaultVoiceHotkeyModifiers),
            Keys.confirmationEnabled:  true,
            Keys.confirmationDuration: 100,
            Keys.imageNormalization:   true,
            Keys.menuBarEnabled:       true,
        ])
    }

    var destinationFolder: String {
        get { defaults.string(forKey: Keys.destinationFolder) ?? NSString(string: "~/_inbox").expandingTildeInPath }
        set { defaults.set(newValue, forKey: Keys.destinationFolder) }
    }

    var destinationFolderURL: URL {
        URL(fileURLWithPath: (destinationFolder as NSString).expandingTildeInPath, isDirectory: true)
    }

    var hotkeyKeyCode: UInt32 {
        get { UInt32(defaults.integer(forKey: Keys.hotkeyKeyCode)) }
        set { defaults.set(Int(newValue), forKey: Keys.hotkeyKeyCode) }
    }

    var hotkeyModifiers: NSEvent.ModifierFlags {
        get {
            let raw = defaults.integer(forKey: Keys.hotkeyModifiers)
            let safe = raw > 0 ? UInt(raw) : Preferences.defaultHotkeyModifiers
            return NSEvent.ModifierFlags(rawValue: safe)
        }
        set { defaults.set(Int(newValue.rawValue), forKey: Keys.hotkeyModifiers) }
    }

    var voiceHotkeyKeyCode: UInt32 {
        get { UInt32(defaults.integer(forKey: Keys.voiceHotkeyKeyCode)) }
        set { defaults.set(Int(newValue), forKey: Keys.voiceHotkeyKeyCode) }
    }

    var voiceHotkeyModifiers: NSEvent.ModifierFlags {
        get {
            let raw = defaults.integer(forKey: Keys.voiceHotkeyModifiers)
            let safe = raw > 0 ? UInt(raw) : Preferences.defaultVoiceHotkeyModifiers
            return NSEvent.ModifierFlags(rawValue: safe)
        }
        set { defaults.set(Int(newValue.rawValue), forKey: Keys.voiceHotkeyModifiers) }
    }

    var confirmationEnabled: Bool {
        get { defaults.bool(forKey: Keys.confirmationEnabled) }
        set { defaults.set(newValue, forKey: Keys.confirmationEnabled) }
    }

    static let confirmationDurationRange: ClosedRange<Int> = 50...2000

    var confirmationDuration: Int {
        get {
            let v = defaults.integer(forKey: Keys.confirmationDuration)
            let raw = v == 0 ? 100 : v
            return Self.confirmationDurationRange.clamp(raw)
        }
        set {
            defaults.set(Self.confirmationDurationRange.clamp(newValue),
                         forKey: Keys.confirmationDuration)
        }
    }

    var imageNormalization: Bool {
        get { defaults.bool(forKey: Keys.imageNormalization) }
        set { defaults.set(newValue, forKey: Keys.imageNormalization) }
    }

    var menuBarEnabled: Bool {
        get { defaults.bool(forKey: Keys.menuBarEnabled) }
        set { defaults.set(newValue, forKey: Keys.menuBarEnabled) }
    }

    var windowPosition: NSPoint? {
        get {
            guard defaults.bool(forKey: Keys.windowPositionSet) else { return nil }
            return NSPoint(x: defaults.double(forKey: Keys.windowOriginX),
                           y: defaults.double(forKey: Keys.windowOriginY))
        }
        set {
            if let p = newValue {
                defaults.set(Double(p.x), forKey: Keys.windowOriginX)
                defaults.set(Double(p.y), forKey: Keys.windowOriginY)
                defaults.set(true,        forKey: Keys.windowPositionSet)
            } else {
                defaults.removeObject(forKey: Keys.windowOriginX)
                defaults.removeObject(forKey: Keys.windowOriginY)
                defaults.set(false, forKey: Keys.windowPositionSet)
            }
        }
    }

    var hasLaunchedBefore: Bool {
        get { defaults.bool(forKey: Keys.hasLaunchedBefore) }
        set { defaults.set(newValue, forKey: Keys.hasLaunchedBefore) }
    }

    /// The relay's base URL (e.g. `https://relay.example.com`), captured during
    /// enrollment from the `stash://enroll?relay=…` deep link. Non-secret, so it
    /// lives in UserDefaults (always readable, even while the screen is locked);
    /// the API key and E2E key live in the Keychain. Nil until enrolled.
    var relayBaseURL: String? {
        get { defaults.string(forKey: Keys.relayBaseURL) }
        set {
            if let v = newValue, !v.isEmpty { defaults.set(v, forKey: Keys.relayBaseURL) }
            else { defaults.removeObject(forKey: Keys.relayBaseURL) }
        }
    }

    var startAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                // Silent — user can manage via System Settings
            }
        }
    }
}

private extension ClosedRange where Bound: Comparable {
    func clamp(_ value: Bound) -> Bound {
        Swift.max(lowerBound, Swift.min(upperBound, value))
    }
}
