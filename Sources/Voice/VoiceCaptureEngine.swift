import AVFoundation
import CoreAudio
import Foundation

/// Captures microphone audio with a single `AVAudioEngine` input tap and fans
/// each buffer out to its consumers (the audio file writer and the transcriber)
/// while computing a smoothed input level for the UI. One tap keeps the audio
/// file and the transcript sample-aligned.
///
/// macOS port of stash-ios `CaptureEngine`. The differences from iOS are the
/// load-bearing part:
///
/// - **No `AVAudioSession`.** That class is iOS-only. On macOS we drive the
///   engine's input node directly; it taps the current system default input
///   device with no session category to configure.
/// - **Two stop triggers, not the iOS route-change notification.** A laptop
///   roams devices (AirPods removed, dock unplugged, a USB interface attached
///   at a different sample rate). We watch:
///     1. The Core-Audio **default-input-device** property
///        (`kAudioHardwarePropertyDefaultInputDevice`) — the device we're
///        recording from went away or was switched.
///     2. **`AVAudioEngineConfigurationChange`** — the engine reconfigured
///        underneath us (route/sample-rate change). If we kept feeding the tap
///        after this, the file garbles or the engine throws.
///   Both route to `onInputUnavailable`; the controller responds by stopping
///   and finalizing what was captured so far (incrementally on disk, so nothing
///   before the change is lost). We deliberately do **not** try to hot-swap the
///   tap mid-stream — stop+finalize is the no-garble behavior the spec wants.
final class VoiceCaptureEngine {
    /// Smoothed input level in 0...1, delivered on the main queue.
    var onLevel: ((Float) -> Void)?
    /// The active input device or engine configuration changed — stop and
    /// finalize. Delivered on the main queue, fired at most once per session.
    var onInputUnavailable: (() -> Void)?

    private let engine = AVAudioEngine()
    private var bufferHandler: ((AVAudioPCMBuffer) -> Void)?
    private var smoothedLevel: Float = 0
    private var observers: [NSObjectProtocol] = []
    private var defaultInputListener: AudioObjectPropertyListenerBlock?
    private let listenerQueue = DispatchQueue(label: "today.wesdo.stash.voice.coreaudio")
    private var didNotifyUnavailable = false
    private(set) var isRunning = false

    /// The hardware input format. Valid (non-zero) only once microphone access
    /// is granted; the controller checks this before building the writer.
    var inputFormat: AVAudioFormat {
        engine.inputNode.outputFormat(forBus: 0)
    }

    /// Installs the tap and starts the engine. `handler` runs on the audio
    /// render thread for every buffer.
    func start(handler: @escaping (AVAudioPCMBuffer) -> Void) throws {
        bufferHandler = handler
        didNotifyUnavailable = false
        registerObservers()

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            // Roll back the partially-installed capture so a retry is clean.
            input.removeTap(onBus: 0)
            removeObservers()
            bufferHandler = nil
            throw error
        }
        isRunning = true
    }

    /// Removes the tap and stops the engine. Idempotent.
    func stop() {
        guard isRunning else { return }
        isRunning = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        bufferHandler = nil
        removeObservers()
    }

    // MARK: - Buffer processing

    private func process(_ buffer: AVAudioPCMBuffer) {
        bufferHandler?(buffer)
        publishLevel(from: buffer)
    }

    private func publishLevel(from buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }
        var sumSquares: Float = 0
        for i in 0..<frames {
            let sample = channel[i]
            sumSquares += sample * sample
        }
        let rms = (sumSquares / Float(frames)).squareRoot()
        // Map RMS to a 0...1 display level on a dB scale, then smooth.
        let db = 20 * log10(max(rms, 1e-7))
        let normalized = max(0, min(1, (db + 50) / 50))   // -50 dB floor
        smoothedLevel += (normalized - smoothedLevel) * 0.2
        let level = smoothedLevel
        DispatchQueue.main.async { [weak self] in self?.onLevel?(level) }
    }

    // MARK: - Device / configuration monitoring

    private func registerObservers() {
        // Engine reconfigured (route/format change) → stop+finalize.
        observers.append(NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine, queue: .main
        ) { [weak self] _ in
            self?.notifyUnavailable()
        })

        // Default input device changed → stop+finalize.
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { self?.notifyUnavailable() }
        }
        defaultInputListener = block
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, listenerQueue, block
        )
    }

    private func removeObservers() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        if let block = defaultInputListener {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultInputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, listenerQueue, block
            )
            defaultInputListener = nil
        }
    }

    /// Fire `onInputUnavailable` once. Guarded so the two triggers (which often
    /// arrive together on a route change) don't double-stop.
    private func notifyUnavailable() {
        guard isRunning, !didNotifyUnavailable else { return }
        didNotifyUnavailable = true
        onInputUnavailable?()
    }
}
