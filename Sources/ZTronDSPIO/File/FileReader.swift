import AVFAudio
import ZTronDSPCore

/// One audio file, read from a position to its end as blocks of Float32, non-interleaved
/// (§6.1), optionally converted to another sample rate on the way (§4.4).
///
/// Threading: not `Sendable`. It is made and repositioned on the control side while no thread
/// reads, and read by the reader thread alone; the hand-over goes through a lock. File reads
/// block and message Objective-C, which is why no other thread ever reads (§4.4).
final class FileReader {
    /// What `next()` delivers: the file's channel count, at the file's rate or the one asked
    /// for.
    let format: SignalFormat
    /// What the file is called in an error.
    private let name: String
    private let file: AVAudioFile
    private let blockSize: Int
    /// What a read fills, in the file's own rate.
    private let chunk: AVAudioPCMBuffer
    private let converter: AVAudioConverter?
    /// What the converter fills, in the rate asked for.
    private let converted: AVAudioPCMBuffer?
    private var inputEnded = false
    private var outputEnded = false

    /// Opens `url` for reading.
    ///
    /// - Parameters:
    ///   - sampleRate: the rate to deliver; `nil`, or the file's own rate, delivers the file's
    ///     samples as they are.
    ///   - blockSize: the most frames one `next()` delivers.
    init(url: URL, sampleRate: Double?, blockSize: Int) throws(DSPError) {
        let name = url.lastPathComponent
        self.name = name
        self.blockSize = blockSize
        guard blockSize >= 1, blockSize <= 1 << 24 else {
            throw .invalidParameter(stage: .none, parameter: "blockSize", reason: "a file is read in blocks of 1 to 16 777 216 frames, not \(blockSize)")
        }
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            throw .sourceUnavailable(reason: "the file \(name) cannot be read: \(error.localizedDescription)")
        }
        self.file = file
        let native = file.processingFormat
        guard native.sampleRate > 0, native.channelCount > 0,
              let chunk = AVAudioPCMBuffer(pcmFormat: native, frameCapacity: AVAudioFrameCount(blockSize)) else {
            // coverage:ignore(a file AVAudioFile opens has a rate and channels, and a buffer of at most 2^24 frames is had)
            throw .sourceUnavailable(reason: "the file \(name) holds no audio the package can read (\(native.sampleRate) Hz, \(native.channelCount) channels)")
        }
        self.chunk = chunk
        guard let sampleRate, sampleRate != native.sampleRate else {
            converter = nil
            converted = nil
            format = SignalFormat(sampleRate: native.sampleRate, channelCount: Int(native.channelCount))
            return
        }
        guard sampleRate.isFinite, sampleRate > 0 else {
            throw .invalidParameter(stage: .none, parameter: "sampleRate", reason: "a file is converted to a positive, finite rate, not \(sampleRate)")
        }
        // The file's own layout at another rate: also right for more than two channels.
        var description = native.streamDescription.pointee
        description.mSampleRate = sampleRate
        guard let target = AVAudioFormat(streamDescription: &description, channelLayout: native.channelLayout),
              let converter = AVAudioConverter(from: native, to: target),
              let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(blockSize)) else {
            throw .unsupportedConfiguration(reason: "the file \(name) cannot be converted from \(native.sampleRate) Hz to \(sampleRate) Hz")
        }
        self.converter = converter
        self.converted = converted
        format = SignalFormat(sampleRate: sampleRate, channelCount: Int(native.channelCount))
    }

    /// The next block: up to `blockSize` frames, valid until the next call. `nil` when the
    /// file has been delivered to its last frame.
    func next() throws(DSPError) -> AudioBlock? {
        if let converter, let converted { return try nextConverted(converter, into: converted) }
        guard try fillChunk() else { return nil }
        return FileReader.block(over: chunk)
    }

    /// Continues from frame `frame`, counted in delivered frames from the start of the file.
    /// With a rate conversion the position is the nearest frame of the file at or before it,
    /// and the converter starts cold.
    func seek(toFrame frame: Int) {
        let ratio = converter == nil ? 1 : file.processingFormat.sampleRate / format.sampleRate
        let position = AVAudioFramePosition((Double(max(frame, 0)) * ratio).rounded(.down))
        file.framePosition = min(position, file.length)
        converter?.reset()
        inputEnded = false
        outputEnded = false
    }

    /// Reads the next frames of the file into `chunk`. False at the end of the file.
    private func fillChunk() throws(DSPError) -> Bool {
        let remaining = file.length - file.framePosition
        guard remaining > 0 else { return false }
        do {
            try file.read(into: chunk, frameCount: AVAudioFrameCount(min(AVAudioFramePosition(blockSize), remaining)))
        } catch {
            throw .sourceUnavailable(reason: "reading the file \(name) failed: \(error.localizedDescription)")
        }
        return chunk.frameLength > 0
    }

    private func nextConverted(_ converter: AVAudioConverter, into converted: AVAudioPCMBuffer) throws(DSPError) -> AudioBlock? {
        guard !outputEnded else { return nil }
        var readFailure: DSPError?
        var conversionFailure: NSError?
        let status = converter.convert(to: converted, error: &conversionFailure) { [self] _, inputStatus in
            do throws(DSPError) {
                // The end of the file is said once, and again should the converter ask again.
                guard !inputEnded, try fillChunk() else {
                    inputEnded = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
            } catch {
                readFailure = error
                inputEnded = true
                inputStatus.pointee = .endOfStream
                return nil
            }
            inputStatus.pointee = .haveData
            return chunk
        }
        if let readFailure { throw readFailure }
        switch status {
        case .haveData, .inputRanDry:
            break
        case .endOfStream:
            outputEnded = true
        case .error:
            throw .sourceUnavailable(reason: "converting the file \(name) failed: \(conversionFailure?.localizedDescription ?? "the converter gave no reason")")
        @unknown default:
            outputEnded = true // coverage:ignore(the converter has four output states, and all four are named above)
        }
        guard converted.frameLength > 0 else {
            // Nothing came out: the converter has given all it had.
            outputEnded = true
            return nil
        }
        return FileReader.block(over: converted)
    }

    /// A view of the valid frames of a Float32, non-interleaved buffer.
    private static func block(over buffer: AVAudioPCMBuffer) -> AudioBlock? {
        guard let channels = buffer.floatChannelData else { return nil }
        let table = UnsafeRawPointer(channels).assumingMemoryBound(to: UnsafeMutablePointer<Float>?.self)
        let frames = Int(buffer.frameLength)
        return AudioBlock(channels: table, channelCount: Int(buffer.format.channelCount), capacity: frames, frameCount: frames)
    }
}
