import Foundation

/// Persists in-progress voice recordings and finalizes them into the vault.
///
/// Adapted from stash-ios `RecordingStore`, but pared down for the macOS hub's
/// M1 scope: the destination is the **local vault `_inbox/`** (a Drive/Cloud
/// mount), there is no library/list, no remote backend, and no outbox cache —
/// a local capture is written straight to the destination.
///
/// What carries over is the **crash/sleep resilience**:
/// - the working file is an ALAC-in-CAF written incrementally (in `AudioFileWriter`),
///   plus a `.cues.json` sidecar updated as cues finalize, so a crash or a
///   forced flush at sleep loses only the tail;
/// - `recoverOrphans` finalizes any leftover working file on next launch/wake.
///
/// Not `@MainActor`: `commit`/`recoverOrphans` are awaited from the main-actor
/// controller but run on the cooperative pool, so the remux and the (possibly
/// slow, Drive-backed) file delivery never block the UI.
final class VoiceRecordingStore {
    private let inProgressDir: URL
    private let fm = FileManager.default

    init() {
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("stash", isDirectory: true)
        inProgressDir = appSupport.appendingPathComponent("VoiceInProgress", isDirectory: true)
        try? fm.createDirectory(at: inProgressDir, withIntermediateDirectories: true)
    }

    // MARK: - Working files (used by VoiceController during capture)

    func makeWorkingFileURL(startDate: Date) -> URL {
        let stamp = VoiceNaming.timestamp(for: startDate)
        return inProgressDir.appendingPathComponent("inprogress_\(stamp).caf")
    }

    func cuesSidecarURL(for workingFile: URL) -> URL {
        workingFile.deletingPathExtension().appendingPathExtension("cues.json")
    }

    func persistCues(_ cues: [TranscriptCue], sidecar: URL) {
        guard let data = try? JSONEncoder().encode(cues) else { return }
        try? data.write(to: sidecar, options: .atomic)
    }

    // MARK: - Commit

    /// Finalizes a finished (or recovered) recording: remuxes the working file
    /// to the delivered lossless container, writes the VTT, and moves both into
    /// the destination folder.
    ///
    /// Returns the finalized `.m4a` bytes (read from the reliable local staging
    /// file) when `returnPublishableAudio` is set and the remux produced an
    /// `.m4a` — so the caller can relay them (M5) without reading back off the
    /// eventually-consistent vault mount. Returns nil otherwise (including on
    /// failure). On success the working file + sidecar are removed; on failure
    /// they are left in place so a later `recoverOrphans` can retry.
    @discardableResult
    func commit(workingFile: URL,
                cuesSidecar: URL?,
                usesALAC: Bool,
                cues: [TranscriptCue],
                startDate: Date,
                destination: URL,
                returnPublishableAudio: Bool = false) async -> Data? {
        guard fm.fileExists(atPath: workingFile.path) else { return nil }
        guard ContentHandler.ensureDirectory(destination) else { return nil }

        // Same-second collisions essentially never happen for voice (recordings
        // can't overlap), but be deterministic if they do. We check the
        // destination here only as a best-effort tiebreak for the local-capture
        // case; the relay consumer (M3+) must NOT infer idempotency from folder
        // contents (the mount is eventually-consistent) — see PLAN.md #7.
        let base = VoiceNaming.uniqueBase(for: startDate) { candidate in
            VoiceNaming.audioExtensions.contains { ext in
                fm.fileExists(atPath: destination
                    .appendingPathComponent(VoiceNaming.audioFilename(base: candidate, ext: ext)).path)
            }
        }

        // Stage the delivered audio next to the working file, then move it in.
        let preferredExt = AudioFinalizer.deliveredExtension(usesALAC: usesALAC)
        var stagedAudio = inProgressDir.appendingPathComponent(VoiceNaming.audioFilename(base: base, ext: preferredExt))
        var deliveredExt = preferredExt
        do {
            try await AudioFinalizer.finalize(source: workingFile, output: stagedAudio, usesALAC: usesALAC)
        } catch {
            // Remux failed: deliver the lossless working file as-is (.caf).
            let cafStaged = inProgressDir.appendingPathComponent(VoiceNaming.audioFilename(base: base, ext: "caf"))
            try? fm.removeItem(at: cafStaged)
            guard (try? fm.copyItem(at: workingFile, to: cafStaged)) != nil else { return nil }
            stagedAudio = cafStaged
            deliveredExt = "caf"
        }

        let audioName = VoiceNaming.audioFilename(base: base, ext: deliveredExt)
        let vttName = VoiceNaming.transcriptFilename(base: base)
        let stagedVTT = inProgressDir.appendingPathComponent(vttName)
        try? VTTWriter.document(from: cues).data(using: .utf8)?.write(to: stagedVTT, options: .atomic)

        // Read the m4a bytes from the local staging file (reliable) before we
        // move it into the (eventually-consistent) vault, for relay publishing.
        let publishAudio: Data? = (returnPublishableAudio && deliveredExt == "m4a")
            ? try? Data(contentsOf: stagedAudio) : nil

        // Deliver the audio first; only treat the recording as committed once
        // it lands. The transcript is best-effort alongside it.
        let audioDelivered = deliver(stagedAudio, to: destination.appendingPathComponent(audioName))
        _ = deliver(stagedVTT, to: destination.appendingPathComponent(vttName))

        if audioDelivered {
            try? fm.removeItem(at: workingFile)
            if let cuesSidecar { try? fm.removeItem(at: cuesSidecar) }
            return publishAudio
        } else {
            // Leave the working file for recovery; clear stale staged copies.
            try? fm.removeItem(at: stagedAudio)
            try? fm.removeItem(at: stagedVTT)
            return nil
        }
    }

    // MARK: - Crash / sleep recovery

    /// Finalizes any leftover working file (from a crash or a sleep-forced
    /// flush) into the destination. Safe to call only when not recording.
    func recoverOrphans(destination: URL) async {
        let names = (try? fm.contentsOfDirectory(atPath: inProgressDir.path)) ?? []
        for name in names where name.hasPrefix("inprogress_") && name.hasSuffix(".caf") {
            let cafURL = inProgressDir.appendingPathComponent(name)
            let stamp = String(name.dropFirst("inprogress_".count).dropLast(".caf".count))
            let startDate = VoiceNaming.date(fromBase: stamp) ?? Date()
            let cuesURL = cuesSidecarURL(for: cafURL)
            await commit(
                workingFile: cafURL,
                cuesSidecar: cuesURL,
                usesALAC: AudioFinalizer.isALAC(url: cafURL),
                cues: loadCues(cuesURL),
                startDate: startDate,
                destination: destination
            )
        }
    }

    // MARK: - Helpers

    /// Moves `staged` to `dest`, falling back to copy+remove across volumes
    /// (the app-support staging dir and a Drive-mounted vault are different
    /// filesystems, so `moveItem` can't rename across them).
    private func deliver(_ staged: URL, to dest: URL) -> Bool {
        try? fm.removeItem(at: dest)
        if (try? fm.moveItem(at: staged, to: dest)) != nil { return true }
        if (try? fm.copyItem(at: staged, to: dest)) != nil {
            try? fm.removeItem(at: staged)
            return true
        }
        return false
    }

    private func loadCues(_ url: URL) -> [TranscriptCue] {
        guard let data = try? Data(contentsOf: url),
              let cues = try? JSONDecoder().decode([TranscriptCue].self, from: data) else { return [] }
        return cues
    }
}
