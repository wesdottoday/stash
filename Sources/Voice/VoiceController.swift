import AVFoundation
import Foundation

/// Orchestrates a single voice recording: audio capture → working file +
/// transcript, then committing the finished pair into the vault. Drives the
/// toast + menu-bar state through callbacks (no SwiftUI here, unlike the iOS
/// `RecorderController` it ports from — and no Live Activity).
///
/// `@MainActor` so all state transitions and UI callbacks are serialized on the
/// main thread; the heavy work (engine I/O, remux, delivery) is awaited out to
/// background executors inside `VoiceCaptureEngine` / `VoiceRecordingStore`.
@MainActor
final class VoiceController {
    enum Phase: Equatable { case idle, preparing, recording, finalizing }

    // UI callbacks, wired once at launch by the AppDelegate and only ever
    // invoked on the main thread (from main-actor state transitions, or via the
    // engine's main-queue delivery). `nonisolated(unsafe)` lets the non-isolated
    // AppDelegate assign them without ceremony; the main-thread-only contract
    // makes that safe.

    /// Phase transitions (drives toast visibility + menu-bar icon).
    nonisolated(unsafe) var onPhaseChange: ((Phase) -> Void)?
    /// Smoothed input level 0...1 (drives the toast level meter / dot).
    nonisolated(unsafe) var onLevel: ((Float) -> Void)?
    /// Latest live one-line transcript (volatile text).
    nonisolated(unsafe) var onLiveLine: ((String) -> Void)?
    /// Recording actually began at this instant (start the elapsed timer).
    nonisolated(unsafe) var onStarted: ((Date) -> Void)?
    /// A user-visible failure (e.g. mic denied). The toast surfaces it because
    /// an `.accessory` app has no window to anchor an alert.
    nonisolated(unsafe) var onError: ((String) -> Void)?
    /// A committed recording is ready to relay (M5): finalized `.m4a` bytes, the
    /// VTT, and the capture time. Only fired when enrolled.
    nonisolated(unsafe) var onPublish: ((Data, String, Date) -> Void)?

    private(set) var phase: Phase = .idle {
        didSet { if phase != oldValue { onPhaseChange?(phase) } }
    }
    var isRecording: Bool { phase == .recording }

    private let store = VoiceRecordingStore()
    private let capture = VoiceCaptureEngine()
    private let transcriber = VoiceTranscriber()
    private let prefs: Preferences

    private var writer: AudioFileWriter?
    private var workingURL: URL?
    private var cuesSidecar: URL?
    private var startDate: Date?
    private var liveCues: [TranscriptCue] = []

    /// A stop requested while we were still in `.preparing` (the async start
    /// hadn't reached `.recording` yet). Honored as soon as setup completes.
    private enum PendingStop { case none, save, discard }
    private var pendingStop: PendingStop = .none

    init(prefs: Preferences = .shared) {
        self.prefs = prefs
        capture.onLevel = { [weak self] level in self?.onLevel?(level) }
        capture.onInputUnavailable = { [weak self] in
            // The input device or engine config changed — stop and keep what we
            // captured (it's already on disk). Saving, not discarding.
            self?.requestStopSaving()
        }
    }

    // MARK: - Public controls
    //
    // These are the entry points called from the non-isolated AppDelegate
    // (hotkey callback, toast buttons, sleep/wake/terminate observers). They're
    // `nonisolated` so those synchronous call sites compile, and they hop onto
    // the main actor to do the actual work.

    /// Global voice chord: start when idle, stop-and-save when recording.
    nonisolated func toggle() {
        Task { @MainActor in
            switch self.phase {
            case .idle: await self.start()
            case .recording: await self.stop(discard: false)
            case .preparing, .finalizing: break   // ignore re-press during transitions
            }
        }
    }

    /// Stop button on the toast (and the auto-stop triggers): saves.
    nonisolated func requestStopSaving() {
        Task { @MainActor in await self.stop(discard: false) }
    }

    /// Escape on the toast: discards the in-progress recording.
    nonisolated func requestDiscard() {
        Task { @MainActor in await self.stop(discard: true) }
    }

    /// `NSWorkspace.willSleepNotification` / app termination: the pre-suspend
    /// window is too short to remux, so force-flush the working file to disk and
    /// leave it as an orphan; `recoverOrphansIfIdle()` finalizes it on
    /// wake/relaunch. Runs synchronously on the calling main thread because it
    /// must complete before the process suspends.
    nonisolated func handleWillSleep() {
        MainActor.assumeIsolated { self.flushForSuspend() }
    }

    @MainActor
    private func flushForSuspend() {
        guard phase == .recording || phase == .preparing else { return }
        capture.stop()
        let working = workingURL
        writer = nil              // releasing the AVAudioFile flushes + closes it
        // Force the flushed working file all the way to disk before the machine
        // suspends — releasing the AVAudioFile flushes to the OS but doesn't
        // fsync, and the crash-recovery story (#6) rests on the .caf surviving.
        if let working {
            let fd = open(working.path, O_RDONLY)
            if fd >= 0 { fsync(fd); close(fd) }
        }
        // The cues sidecar is kept current incrementally (see appendCue), so no
        // extra persist is needed; we deliberately skip transcriber.finish()
        // (async + slow) — we lose only the trailing un-finalized utterance.
        resetTransient()
        phase = .idle
    }

    /// Finalize any leftover working file from a crash or a sleep-forced flush.
    /// No-op while a recording is active (its working file must not be touched).
    nonisolated func recoverOrphansIfIdle() {
        Task { @MainActor in
            guard self.phase == .idle else { return }
            await self.store.recoverOrphans(destination: self.prefs.destinationFolderURL)
        }
    }

    // MARK: - Start

    private func start() async {
        guard phase == .idle else { return }
        phase = .preparing
        pendingStop = .none
        liveCues = []
        onLiveLine?("")
        onLevel?(0)

        guard await VoicePermissions.requestMicrophone() else {
            phase = .idle
            onError?("Microphone access is off. Turn it on in System Settings ▸ Privacy & Security ▸ Microphone.")
            return
        }
        // Honor a discard requested during the permission prompt.
        if pendingStop != .none { pendingStop = .none; phase = .idle; return }

        let speechGranted = await VoicePermissions.requestSpeech()
        let modelStatus = await VoiceTranscriber.status()
        if pendingStop != .none { pendingStop = .none; phase = .idle; return }

        let hardwareFormat = capture.inputFormat
        guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0 else {
            phase = .idle
            onError?("No audio input is available.")
            return
        }

        let started = Date()
        let working = store.makeWorkingFileURL(startDate: started)
        let sidecar = store.cuesSidecarURL(for: working)

        let newWriter: AudioFileWriter
        do {
            newWriter = try AudioFileWriter(url: working, hardwareFormat: hardwareFormat)
        } catch {
            phase = .idle
            onError?("Couldn't create the recording file.")
            return
        }

        writer = newWriter
        workingURL = working
        cuesSidecar = sidecar
        startDate = started

        // Transcription is best-effort: if it's unavailable, denied, or the
        // on-device model isn't installed, we still capture lossless audio and
        // write an (empty) transcript — symmetric with iOS.
        if speechGranted, modelStatus.isSupported,
           let locale = modelStatus.supportedLocale, modelStatus.isInstalled {
            transcriber.onVolatileText = { [weak self] text in
                Task { @MainActor in self?.onLiveLine?(text) }
            }
            transcriber.onFinalCue = { [weak self] cue in
                Task { @MainActor in self?.appendCue(cue, sidecar: sidecar) }
            }
            try? await transcriber.start(locale: locale, hardwareFormat: hardwareFormat)
        }
        if pendingStop != .none {
            // Discard requested mid-setup: tear down cleanly.
            pendingStop = .none
            await teardownAfterFailedStart()
            return
        }

        let writerRef = newWriter
        let transcriberRef = transcriber
        do {
            try capture.start { buffer in
                try? writerRef.write(buffer)
                transcriberRef.append(buffer)
            }
        } catch {
            await teardownAfterFailedStart()
            onError?("Couldn't start recording.")
            return
        }

        phase = .recording
        onStarted?(started)

        // A save/discard arrived while we were finishing setup — honor it now.
        if pendingStop != .none {
            let action = pendingStop
            pendingStop = .none
            await stop(discard: action == .discard)
        }
    }

    // MARK: - Stop

    private func stop(discard: Bool) async {
        switch phase {
        case .preparing:
            // Setup still in flight — record the intent; start() honors it.
            pendingStop = discard ? .discard : .save
            return
        case .recording:
            break
        case .idle, .finalizing:
            return
        }

        phase = .finalizing
        capture.stop()
        let usesALAC = writer?.usesALAC ?? true
        writer = nil               // flush + close the working file
        // After finish() returns, the results loop has fully drained (it awaits
        // `resultsTask.value`), so `transcriber.cues` is stable to read below.
        await transcriber.finish()

        if discard {
            if let working = workingURL { try? FileManager.default.removeItem(at: working) }
            if let sidecar = cuesSidecar { try? FileManager.default.removeItem(at: sidecar) }
        } else if let working = workingURL, let started = startDate {
            let publishAudio = await store.commit(
                workingFile: working,
                cuesSidecar: cuesSidecar,
                usesALAC: usesALAC,
                cues: transcriber.cues,
                startDate: started,
                destination: prefs.destinationFolderURL,
                returnPublishableAudio: RelayCredentials.isEnrolled
            )
            // Also relay the capture (best-effort, M5) so other clients stay current.
            if let publishAudio {
                let vtt = VTTWriter.document(from: transcriber.cues)
                onPublish?(publishAudio, vtt, started)
            }
        }

        resetTransient()
        phase = .idle
    }

    // MARK: - Helpers

    private func appendCue(_ cue: TranscriptCue, sidecar: URL) {
        liveCues.append(cue)
        store.persistCues(liveCues, sidecar: sidecar)
    }

    /// Tear down a half-started session (engine failed to start, or a discard
    /// arrived mid-setup) and remove its working files.
    private func teardownAfterFailedStart() async {
        capture.stop()
        await transcriber.finish()
        if let working = workingURL { try? FileManager.default.removeItem(at: working) }
        if let sidecar = cuesSidecar { try? FileManager.default.removeItem(at: sidecar) }
        resetTransient()
        phase = .idle
    }

    private func resetTransient() {
        writer = nil
        workingURL = nil
        cuesSidecar = nil
        startDate = nil
        liveCues = []
        onLiveLine?("")
        onLevel?(0)
    }
}
