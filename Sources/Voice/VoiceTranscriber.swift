import AVFoundation
import Foundation
import Speech

/// On-device live transcription using the macOS 26 `SpeechAnalyzer` /
/// `SpeechTranscriber` (the same on-device API iOS 26 uses, which is why the
/// macOS minimum was bumped to 26 for parity). Audio buffers from
/// `VoiceCaptureEngine` are converted to the analyzer's preferred format and
/// streamed in; results come back as volatile text (drives the live one-liner)
/// and finalized, time-ranged segments (become VTT cues via their `CMTimeRange`).
///
/// Ported from stash-ios `Transcriber`. The Speech API is platform-agnostic, so
/// this is essentially unchanged.
final class VoiceTranscriber {
    enum TranscriberError: Error { case unavailable, localeUnsupported }

    /// Whether the device locale is supported and its model already installed.
    struct ModelStatus {
        let supportedLocale: Locale?
        let isInstalled: Bool
        var isSupported: Bool { supportedLocale != nil }
    }

    /// Latest volatile (not-yet-final) text — the live sanity-check line.
    var onVolatileText: ((String) -> Void)?
    /// A finalized transcript segment.
    var onFinalCue: ((TranscriptCue) -> Void)?

    /// All finalized cues for the current session, in order.
    private(set) var cues: [TranscriptCue] = []

    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var analyzerFormat: AVAudioFormat?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var converter: AVAudioConverter?
    private var resultsTask: Task<Void, Never>?

    // MARK: - Model management

    /// Resolves the device-default locale against the transcriber's supported
    /// locales and reports whether its model is installed.
    static func status() async -> ModelStatus {
        let supported = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current)
        guard let supported else { return ModelStatus(supportedLocale: nil, isInstalled: false) }
        let installed = await SpeechTranscriber.installedLocales
        let isInstalled = installed.contains { $0.identifier(.bcp47) == supported.identifier(.bcp47) }
        return ModelStatus(supportedLocale: supported, isInstalled: isInstalled)
    }

    /// Downloads and installs the on-device model for `locale` if needed,
    /// reporting download progress in 0...1. Reserves the locale so the asset
    /// stays allocated for future launches (best effort).
    static func installModel(for locale: Locale, progress: @escaping (Double) -> Void) async throws {
        let module = makeTranscriber(locale: locale)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            let observation = request.progress.observe(\.fractionCompleted) { prog, _ in
                progress(prog.fractionCompleted)
            }
            defer { observation.invalidate() }
            try await request.downloadAndInstall()
        }
        progress(1.0)
        _ = try? await AssetInventory.reserve(locale: locale)
    }

    private static func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange]
        )
    }

    // MARK: - Live session

    /// Begins a transcription session for `locale`, expecting audio buffers in
    /// `hardwareFormat`. Throws if transcription is unavailable on this device.
    func start(locale: Locale, hardwareFormat: AVAudioFormat) async throws {
        guard SpeechTranscriber.isAvailable else { throw TranscriberError.unavailable }
        cues.removeAll()

        let module = VoiceTranscriber.makeTranscriber(locale: locale)
        let analyzer = SpeechAnalyzer(modules: [module])
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module])

        self.transcriber = module
        self.analyzer = analyzer
        self.analyzerFormat = format
        if let format {
            converter = AVAudioConverter(from: hardwareFormat, to: format)
        }

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.inputContinuation = continuation

        resultsTask = Task { [weak self] in
            guard let self, let module = self.transcriber else { return }
            do {
                for try await result in module.results {
                    self.handle(result)
                }
            } catch {
                // Stream ended with an error (e.g. cancellation). Finalized cues
                // captured so far are still valid and will be written out.
            }
        }

        try await analyzer.start(inputSequence: stream)
    }

    /// Feeds one captured buffer into the analyzer. Safe to call from the audio
    /// render thread.
    func append(_ buffer: AVAudioPCMBuffer) {
        guard let continuation = inputContinuation else { return }
        guard let format = analyzerFormat, let converter, buffer.format != format else {
            continuation.yield(AnalyzerInput(buffer: buffer))
            return
        }
        guard let converted = convert(buffer, using: converter, to: format) else { return }
        continuation.yield(AnalyzerInput(buffer: converted))
    }

    /// Stops input and finalizes the transcript. After this returns, `cues`
    /// holds every finalized segment.
    func finish() async {
        inputContinuation?.finish()
        inputContinuation = nil
        if let analyzer {
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
        }
        await resultsTask?.value
        resultsTask = nil
        transcriber = nil
        analyzer = nil
        converter = nil
    }

    // MARK: - Internals

    private func handle(_ result: SpeechTranscriber.Result) {
        let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        if result.isFinal {
            if !text.isEmpty {
                let cue = TranscriptCue(
                    start: max(0, result.range.start.seconds),
                    end: result.range.end.seconds,
                    text: text
                )
                cues.append(cue)
                onFinalCue?(cue)
            }
            onVolatileText?("")
        } else if !text.isEmpty {
            onVolatileText?(text)
        }
    }

    private func convert(_ buffer: AVAudioPCMBuffer,
                         using converter: AVAudioConverter,
                         to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var provided = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if provided {
                inputStatus.pointee = .noDataNow
                return nil
            }
            provided = true
            inputStatus.pointee = .haveData
            return buffer
        }
        if status == .error || output.frameLength == 0 { return nil }
        return output
    }
}
