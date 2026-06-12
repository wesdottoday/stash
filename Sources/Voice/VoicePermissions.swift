import AVFoundation
import Speech

/// Microphone and speech-recognition authorization for macOS.
///
/// Unlike iOS (which gates the mic through `AVAudioApplication`/`AVAudioSession`),
/// macOS uses the capture-device TCC API. Both prompts use the usage strings
/// declared in Info.plist (`NSMicrophoneUsageDescription`,
/// `NSSpeechRecognitionUsageDescription`). The app runs as an `.accessory` (no
/// Dock/window), so a denial surfaces in the voice toast rather than an alert.
enum VoicePermissions {
    /// Requests microphone access, returning the resulting grant. A prior
    /// denial returns `false` immediately (macOS won't re-prompt — the user
    /// must change it in System Settings).
    static func requestMicrophone() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    static var microphoneGranted: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static func requestSpeech() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    static var speechGranted: Bool {
        SFSpeechRecognizer.authorizationStatus() == .authorized
    }
}
