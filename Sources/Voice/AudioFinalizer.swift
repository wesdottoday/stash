import AVFoundation

/// Turns the crash-resilient `.caf` working file into the lossless file we
/// deliver into the vault. ALAC is remuxed into `.m4a` by passthrough (no
/// re-encode); PCM is written to `.wav`. Neither path loses fidelity.
///
/// Ported from stash-ios for byte-compatible output.
enum AudioFinalizer {
    enum FinalizerError: Error { case cannotCreateExportSession, exportFailed, pcmReadFailed }

    /// The delivered file extension for the given working file.
    static func deliveredExtension(usesALAC: Bool) -> String {
        usesALAC ? "m4a" : "wav"
    }

    /// Produces the delivered audio file at `output` from the working `.caf` at
    /// `source`. `output`'s extension must match `deliveredExtension`.
    static func finalize(source: URL, output: URL, usesALAC: Bool) async throws {
        try? FileManager.default.removeItem(at: output)
        if usesALAC {
            try await remuxToM4A(source: source, output: output)
        } else {
            try writeWAV(source: source, output: output)
        }
    }

    /// Lossless container change: ALAC-in-CAF → ALAC-in-M4A, no transcode.
    private static func remuxToM4A(source: URL, output: URL) async throws {
        let asset = AVURLAsset(url: source)
        guard let export = AVAssetExportSession(
            asset: asset, presetName: AVAssetExportPresetPassthrough
        ) else { throw FinalizerError.cannotCreateExportSession }
        do {
            try await export.export(to: output, as: .m4a)
        } catch {
            throw FinalizerError.exportFailed
        }
    }

    /// Lossless rewrite of PCM-in-CAF → PCM-in-WAV.
    private static func writeWAV(source: URL, output: URL) throws {
        let input = try AVAudioFile(forReading: source)
        let format = input.processingFormat
        let wavSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let out = try AVAudioFile(
            forWriting: output, settings: wavSettings,
            commonFormat: .pcmFormatFloat32, interleaved: false
        )
        let chunk: AVAudioFrameCount = 16384
        while input.framePosition < input.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else {
                throw FinalizerError.pcmReadFailed
            }
            try input.read(into: buffer)
            if buffer.frameLength == 0 { break }
            try out.write(from: buffer)
        }
    }

    /// Whether a working file's on-disk format is ALAC (vs. PCM). Used by
    /// orphan recovery to choose the delivered container.
    static func isALAC(url: URL) -> Bool {
        guard let file = try? AVAudioFile(forReading: url) else { return false }
        return file.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatAppleLossless
    }
}
