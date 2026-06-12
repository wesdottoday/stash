import AVFoundation

/// Writes captured audio to disk incrementally as buffers arrive.
///
/// The working file is **ALAC (Apple Lossless) inside a CAF container**. CAF is
/// chosen for the working file because it is resilient to a crash mid-recording
/// — a leftover `.caf` can be recovered and finalized on the next launch,
/// whereas an unfinalized `.m4a` (missing its `moov` atom) is unreadable. On a
/// clean stop the `.caf` is losslessly remuxed to the `.m4a` we deliver
/// (see `AudioFinalizer`). If ALAC can't be opened for the active route we fall
/// back to 32-bit float Linear PCM (still lossless).
///
/// Ported from stash-ios for byte-compatible output. The macOS engine drives
/// the input node directly (no `AVAudioSession`), but the writer itself is
/// platform-agnostic AVFoundation and is unchanged.
final class AudioFileWriter {
    let url: URL
    /// The format buffers must be in to be written (the file's processing
    /// format). Buffers in another format are converted automatically.
    let processingFormat: AVAudioFormat
    /// True when ALAC (lossless, compact) is in use; false when we fell back to
    /// 32-bit float Linear PCM (also lossless). Determines the delivered
    /// container: ALAC → `.m4a`, PCM → `.wav`.
    let usesALAC: Bool

    private let file: AVAudioFile
    private var converter: AVAudioConverter?
    private var converterSourceFormat: AVAudioFormat?

    init(url: URL, hardwareFormat: AVAudioFormat) throws {
        self.url = url
        let sampleRate = hardwareFormat.sampleRate
        let channels = hardwareFormat.channelCount

        let alacSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatAppleLossless,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderAudioQualityKey: AVAudioQuality.max.rawValue,
            AVEncoderBitDepthHintKey: 24,
        ]
        let pcmSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ]

        if let alac = try? AVAudioFile(
            forWriting: url, settings: alacSettings,
            commonFormat: .pcmFormatFloat32, interleaved: false
        ) {
            self.file = alac
            self.usesALAC = true
        } else {
            self.file = try AVAudioFile(
                forWriting: url, settings: pcmSettings,
                commonFormat: .pcmFormatFloat32, interleaved: false
            )
            self.usesALAC = false
        }
        self.processingFormat = file.processingFormat
    }

    /// Appends a buffer, converting from the tap's format if necessary. Safe to
    /// call from the audio render thread.
    func write(_ buffer: AVAudioPCMBuffer) throws {
        if buffer.format == processingFormat {
            try file.write(from: buffer)
            return
        }
        let converted = try convert(buffer)
        try file.write(from: converted)
    }

    private func convert(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        if converter == nil || converterSourceFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: processingFormat)
            converterSourceFormat = buffer.format
        }
        guard let converter,
              let output = AVAudioPCMBuffer(
                pcmFormat: processingFormat,
                frameCapacity: buffer.frameLength)
        else { throw CocoaError(.fileWriteUnknown) }
        // Same sample rate (file SR == hardware SR): a pure layout/format
        // conversion preserves frame count, so the simple API is correct.
        try converter.convert(to: output, from: buffer)
        return output
    }
}
