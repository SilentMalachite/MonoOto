import AVFoundation
import AudioToolbox
import Foundation

public enum AudioFilePipelineError: Error, Equatable, Sendable {
    case unsupportedContainer, unsupportedPCM, unsupportedSampleRate, unsupportedChannelCount
    case invalidFile, decodeFailed, conversionFailed, nonfiniteAudio, invalidReadSize
    case invalidSeek, invalidGain, stereoRequired, faulted
}

/// Synchronous, single-worker-owned file processing. Never call from an audio callback or
/// concurrently. Each read returns at most 1024 frames, regardless of the requested size.
/// Resamplers use normal priming: synthesized trailing samples are drained through EOS,
/// without adding a leading SRC delay. Nonempty output includes the guard's 5 ms delay
/// and exactly that many drain frames. reset rewinds; seek discards all prefetch and tails.
public final class AudioFilePipeline {
    /// True if the latest read observed a cancellation condition, even if it cleared
    /// within that read. The current condition carries across prefetched blocks.
    public private(set) var cancellationWarning = false
    private var currentCancellationWarning = false
    public private(set) var isFaulted = false
    public let sourceFrameCount: Int64
    public let sourceRate: Double
    public let channelCount: Int
    public let outputRate: Double
    public let latencyFrames: Int
    public static let maximumReadFrames = 1_024

    private let file: AVAudioFile
    private let decoded: AVAudioPCMBuffer
    private let encoded: AVAudioPCMBuffer
    private let inputConverter: FilePCMConverter
    private let outputConverter: FilePCMConverter
    private let encoder: Encoder
    private let outputGuard: OutputGuard
    private var gain = Double(Float(pow(10.0, -18.0 / 20)))
    private var targetGain = Double(Float(pow(10.0, -18.0 / 20)))
    private var gainStep = 0.0
    private var gainFramesRemaining = 0
    private static let gainTransitionFrames = 960
    private var fadeFrame = 0
    private var pending = [Float](repeating: 0, count: maximumReadFrames)
    private var pendingIndex = 0
    private var pendingCount = 0
    private var convertedEnded = false
    private var producedAudio = false
    private var tailRemaining = 0

    public init(url: URL, outputRate: Double) throws {
        guard outputRate == 44_100 || outputRate == 48_000 else {
            throw AudioFilePipelineError.unsupportedSampleRate
        }
        try Self.validateFile(url)
        do { file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false) }
        catch { throw AudioFilePipelineError.invalidFile }
        try Self.validatePCM(file.fileFormat.streamDescription.pointee)
        guard file.processingFormat.sampleRate == file.fileFormat.sampleRate,
              file.processingFormat.channelCount == file.fileFormat.channelCount,
              file.length >= 0 else { throw AudioFilePipelineError.invalidFile }
        sourceFrameCount = file.length
        sourceRate = file.processingFormat.sampleRate
        channelCount = Int(file.processingFormat.channelCount)
        self.outputRate = outputRate
        guard let dspFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: file.processingFormat.channelCount),
              let monoFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1),
              let outputFormat = AVAudioFormat(standardFormatWithSampleRate: outputRate, channels: 1),
              let decoded = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(Self.maximumReadFrames)),
              let encoded = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: AVAudioFrameCount(Self.maximumReadFrames)) else {
            throw AudioFilePipelineError.conversionFailed
        }
        self.decoded = decoded
        self.encoded = encoded
        inputConverter = try FilePCMConverter(from: file.processingFormat, to: dspFormat)
        outputConverter = try FilePCMConverter(from: monoFormat, to: outputFormat)
        encoder = try Encoder(parameters: .init(strength: 0.35, cutoffHz: 1_500))
        outputGuard = try OutputGuard(sampleRate: outputRate)
        latencyFrames = outputGuard.latencyFrames
    }

    public func read(maxFrames: Int) throws -> [Float] {
        guard maxFrames > 0 else { throw AudioFilePipelineError.invalidReadSize }
        guard !isFaulted else { throw AudioFilePipelineError.faulted }
        cancellationWarning = currentCancellationWarning
        let limit = min(maxFrames, Self.maximumReadFrames)
        var result: [Float] = []
        result.reserveCapacity(limit)
        do {
            while result.count < limit {
                if pendingIndex == pendingCount {
                    try fillPending()
                    if pendingCount == 0 { break }
                }
                let count = min(limit - result.count, pendingCount - pendingIndex)
                result.append(contentsOf: pending[pendingIndex..<(pendingIndex + count)])
                pendingIndex += count
            }
            return result
        } catch {
            // Never return the partially assembled read, or retain audio after a fault.
            isFaulted = true
            clearProcessingState()
            throw error
        }
    }

    /// nil is explicit mute; all numeric gain values must be finite and <= 0 dB.
    /// Updates take effect at the next DSP block, after any bounded prefetched output.
    /// Numeric gain changes ramp linearly over 20 ms; explicit mute takes effect
    /// at that boundary without a ramp. seek/reset starts at the selected gain.
    public func set(mode: ListeningMode, parameters: EncoderParameters, gainDB: Float?) throws {
        if let gainDB, !gainDB.isFinite || gainDB > 0 { throw AudioFilePipelineError.invalidGain }
        if channelCount == 1, mode == .leftOnly || mode == .rightOnly {
            throw AudioFilePipelineError.stereoRequired
        }
        // Encoder validates before mutating. Complete all validation before changing other state.
        try encoder.setParameters(parameters)
        encoder.setMode(mode)
        targetGain = Double(gainDB.map { Float(pow(10.0, Double($0) / 20)) } ?? 0)
        if gainDB == nil {
            gain = 0
            gainStep = 0
            gainFramesRemaining = 0
        } else {
            gainStep = (targetGain - gain) / Double(Self.gainTransitionFrames)
            gainFramesRemaining = Self.gainTransitionFrames
        }
    }

    public func seek(sourceFrame: Int64) throws {
        guard (0...sourceFrameCount).contains(sourceFrame) else { throw AudioFilePipelineError.invalidSeek }
        file.framePosition = sourceFrame
        clearProcessingState()
        isFaulted = false
    }

    public func reset() {
        file.framePosition = 0
        clearProcessingState()
        isFaulted = false
    }

    private func clearProcessingState() {
        inputConverter.reset()
        outputConverter.reset()
        encoder.reset()
        outputGuard.reset()
        decoded.frameLength = 0
        encoded.frameLength = 0
        pendingIndex = 0
        pendingCount = 0
        for i in pending.indices { pending[i] = 0 }
        fadeFrame = 0
        gain = targetGain
        gainStep = 0
        gainFramesRemaining = 0
        convertedEnded = false
        producedAudio = false
        tailRemaining = 0
        cancellationWarning = false
        currentCancellationWarning = false
    }

    private func decode(_ requested: AVAudioPacketCount) throws -> AVAudioPCMBuffer? {
        guard file.framePosition < sourceFrameCount else { return nil }
        let count = min(AVAudioFrameCount(Self.maximumReadFrames), requested)
        guard count > 0 else { throw AudioFilePipelineError.conversionFailed }
        do { try file.read(into: decoded, frameCount: count) }
        catch { throw AudioFilePipelineError.decodeFailed }
        guard decoded.frameLength > 0 else { throw AudioFilePipelineError.decodeFailed }
        try FilePCMConverter.validate(decoded)
        return decoded
    }

    private func encode(_ requested: AVAudioPacketCount) throws -> AVAudioPCMBuffer? {
        guard let input = try inputConverter.next(requested: requested, input: decode) else { return nil }
        try FilePCMConverter.validate(input)
        encoded.frameLength = input.frameLength
        let channels = input.floatChannelData!
        let output = encoded.floatChannelData![0]
        for i in 0..<Int(input.frameLength) {
            let sample = encoder.process(left: channels[0][i], right: channels[channelCount == 1 ? 0 : 1][i])
            guard !encoder.isFaulted, sample.mono.isFinite else { throw AudioFilePipelineError.nonfiniteAudio }
            currentCancellationWarning = sample.cancellationWarning
            cancellationWarning = cancellationWarning || currentCancellationWarning
            if gainFramesRemaining > 0 {
                gain += gainStep
                gainFramesRemaining -= 1
                if gainFramesRemaining == 0 { gain = targetGain }
            }
            output[i] = sample.mono * Float(gain) * min(1, Float(fadeFrame) / 4_800)
            fadeFrame = min(fadeFrame + 1, 4_800)
        }
        try FilePCMConverter.validate(encoded)
        return encoded
    }

    private func fillPending() throws {
        pendingIndex = 0
        pendingCount = 0
        if !convertedEnded {
            if let output = try outputConverter.next(requested: AVAudioPacketCount(Self.maximumReadFrames), input: encode) {
                try FilePCMConverter.validate(output)
                producedAudio = true
                pendingCount = Int(output.frameLength)
                for i in 0..<pendingCount { pending[i] = outputGuard.process(output.floatChannelData![0][i]) }
                guard !outputGuard.faulted else { throw AudioFilePipelineError.nonfiniteAudio }
                return
            }
            convertedEnded = true
            tailRemaining = producedAudio ? latencyFrames : 0
        }
        pendingCount = min(tailRemaining, Self.maximumReadFrames)
        for i in 0..<pendingCount { pending[i] = outputGuard.process(0) }
        tailRemaining -= pendingCount
        guard !outputGuard.faulted else { throw AudioFilePipelineError.nonfiniteAudio }
    }

    private static func validateFile(_ url: URL) throws {
        // Verify real RIFF/WAVE or FORM/AIFF/AIFC bytes, including advertised chunk extents.
        // This also rejects a truncated data chunk that AVAudioFile might silently shorten.
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let size = try handle.seekToEnd()
            try handle.seek(toOffset: 0)
            let header = try handle.read(upToCount: 12) ?? Data()
            guard header.count == 12 else { throw AudioFilePipelineError.invalidFile }
            let tag = String(decoding: header[0..<4], as: UTF8.self)
            let type = String(decoding: header[8..<12], as: UTF8.self)
            let little = tag == "RIFF" && type == "WAVE"
            guard little || (tag == "FORM" && (type == "AIFF" || type == "AIFC")) else {
                throw AudioFilePipelineError.unsupportedContainer
            }
            func uint32(_ data: Data, _ offset: Int) -> UInt64 {
                let bytes = Array(data[offset..<(offset + 4)])
                return (little ? Array(bytes.reversed()) : bytes).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            }
            let end = uint32(header, 4) + 8
            guard end >= 12, end <= size else { throw AudioFilePipelineError.invalidFile }
            var position: UInt64 = 12
            var chunks = 0
            while position < end {
                guard end - position >= 8, chunks < 4_096 else { throw AudioFilePipelineError.invalidFile }
                try handle.seek(toOffset: position)
                let chunk = try handle.read(upToCount: 8) ?? Data()
                guard chunk.count == 8 else { throw AudioFilePipelineError.invalidFile }
                let length = uint32(chunk, 4)
                // Apple may omit the final pad byte for odd-sized PCM data.
                position += 8 + length
                if position < end { position += length % 2 }
                guard position <= end else { throw AudioFilePipelineError.invalidFile }
                chunks += 1
            }
        } catch let error as AudioFilePipelineError { throw error }
        catch { throw AudioFilePipelineError.invalidFile }

    }

    private static func validatePCM(_ format: AudioStreamBasicDescription) throws {
        guard format.mSampleRate == 44_100 || format.mSampleRate == 48_000 else {
            throw AudioFilePipelineError.unsupportedSampleRate
        }
        guard format.mChannelsPerFrame == 1 || format.mChannelsPerFrame == 2 else {
            throw AudioFilePipelineError.unsupportedChannelCount
        }
        let floating = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let signed = format.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0
        let packed = format.mFormatFlags & kAudioFormatFlagIsPacked != 0
        guard format.mFormatID == kAudioFormatLinearPCM, packed,
              (floating && !signed && format.mBitsPerChannel == 32) ||
              (!floating && signed && (format.mBitsPerChannel == 16 || format.mBitsPerChannel == 24)),
              format.mBytesPerFrame == format.mChannelsPerFrame * (format.mBitsPerChannel / 8),
              format.mFramesPerPacket == 1, format.mBytesPerPacket == format.mBytesPerFrame,
              format.mFormatFlags & (kAudioFormatFlagIsNonInterleaved | kAudioFormatFlagIsAlignedHigh) == 0 else {
            throw AudioFilePipelineError.unsupportedPCM
        }
    }
}

/// Owns a stream's converter and output storage through EOF/reset. Input storage is retained
/// by its provider and is reused only on the next synchronous input request. Separate storage
/// for each stage prevents nested pulls from overwriting a buffer still being converted.
private final class FilePCMConverter {
    private let converter: AVAudioConverter?
    private let output: AVAudioPCMBuffer
    private var ended = false

    init(from: AVAudioFormat, to: AVAudioFormat) throws {
        guard let output = AVAudioPCMBuffer(pcmFormat: to, frameCapacity: AVAudioFrameCount(AudioFilePipeline.maximumReadFrames)) else {
            throw AudioFilePipelineError.conversionFailed
        }
        self.output = output
        if from == to { converter = nil }
        else {
            guard let converter = AVAudioConverter(from: from, to: to) else { throw AudioFilePipelineError.conversionFailed }
            converter.primeMethod = .normal
            self.converter = converter
        }
    }

    func reset() {
        converter?.reset()
        output.frameLength = 0
        ended = false
    }

    func next(requested: AVAudioPacketCount,
              input: @escaping (AVAudioPacketCount) throws -> AVAudioPCMBuffer?) throws -> AVAudioPCMBuffer? {
        guard !ended else { return nil }
        guard let converter else {
            let buffer = try input(min(requested, AVAudioPacketCount(AudioFilePipeline.maximumReadFrames)))
            if buffer == nil { ended = true }
            return buffer
        }
        var error: NSError?
        // AVAudioConverter invokes this input block synchronously during convert.
        // The SDK marks it Sendable; neither this closure nor these locals escape the call.
        nonisolated(unsafe) let provider = input
        nonisolated(unsafe) var inputError: Error?
        output.frameLength = 0
        let status = converter.convert(to: output, error: &error) { count, status in
            do {
                guard inputError == nil else { status.pointee = .endOfStream; return nil }
                guard let buffer = try provider(min(count, AVAudioPacketCount(AudioFilePipeline.maximumReadFrames))) else {
                    status.pointee = .endOfStream
                    return nil
                }
                try Self.validate(buffer)
                status.pointee = .haveData
                return buffer
            } catch {
                inputError = error
                status.pointee = .endOfStream
                return nil
            }
        }
        if let inputError { throw inputError }
        guard error == nil, status != .error else { throw AudioFilePipelineError.conversionFailed }
        if status == .endOfStream { ended = true }
        try Self.validate(output)
        if output.frameLength > 0 { return output }
        guard ended else { throw AudioFilePipelineError.conversionFailed }
        return nil
    }

    static func validate(_ buffer: AVAudioPCMBuffer) throws {
        guard buffer.frameLength <= buffer.frameCapacity, buffer.frameLength <= AVAudioFrameCount(AudioFilePipeline.maximumReadFrames),
              let channels = buffer.floatChannelData else { throw AudioFilePipelineError.conversionFailed }
        for channel in 0..<Int(buffer.format.channelCount) {
            for i in 0..<Int(buffer.frameLength) where !channels[channel][i].isFinite {
                throw AudioFilePipelineError.nonfiniteAudio
            }
        }
    }
}
