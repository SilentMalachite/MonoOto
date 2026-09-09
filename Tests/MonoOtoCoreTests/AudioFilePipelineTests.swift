import AVFoundation
import XCTest
@testable import MonoOtoCore

final class AudioFilePipelineTests: XCTestCase {
    private var directory: URL!
    private let parameters = EncoderParameters(strength: 0.35, cutoffHz: 1_500)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func fixture(ext: String = "wav", rate: Double = 48_000, channels: Int = 2,
                         bits: Int = 32, floating: Bool = true, frames: Int = 6_013,
                         sample: (Int, Int) -> Float = { i, _ in Float(sin(Double(i) * 0.07)) * 0.2 }) throws -> URL {
        let url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate, AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: bits, AVLinearPCMIsFloatKey: floating,
            AVLinearPCMIsBigEndianKey: ext == "aiff", AVLinearPCMIsNonInterleaved: false]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(max(1, frames)))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for c in 0..<channels { for i in 0..<frames { buffer.floatChannelData![c][i] = sample(i, c) } }
        if frames > 0 { try file.write(from: buffer) }
        return url
    }
    private func collect(_ pipeline: AudioFilePipeline, block: Int = 137) throws -> [Float] {
        var output: [Float] = []
        for _ in 0..<100_000 {
            let part = try pipeline.read(maxFrames: block)
            XCTAssertLessThanOrEqual(part.count, min(block, 1_024))
            if part.isEmpty { return output }
            output += part
        }
        XCTFail("EOF did not terminate")
        return output
    }
    private func prepare(_ url: URL, rate: Double = 48_000, mode: ListeningMode = .mono,
                         gain: Float? = 0) throws -> AudioFilePipeline {
        let pipeline = try AudioFilePipeline(url: url, outputRate: rate)
        try pipeline.set(mode: mode, parameters: parameters, gainDB: gain)
        pipeline.reset()
        return pipeline
    }

    // Detect wrong channel mixing, missing start fade, gain bypass, delayed/lost final samples.
    func testIndependentOfflineReferenceAndCueFormula() throws {
        let url = try fixture(sample: { i, c in Float(sin(Double(i) * (c == 0 ? 0.07 : 0.13))) * 0.2 })
        for mode in [ListeningMode.mono, .cue, .leftOnly, .rightOnly] {
            let output = try collect(prepare(url, mode: mode, gain: -18))
            var expected = Array(repeating: Float(0), count: 240)
            var low = 0.0
            let coefficient = exp(-2 * Double.pi * 1_500 / 48_000)
            for i in 0..<6_013 {
                let l = Double(Float(sin(Double(i) * 0.07)) * 0.2)
                let r = Double(Float(sin(Double(i) * 0.13)) * 0.2)
                let side = (l - r) / 2
                low = (1 - coefficient) * side + coefficient * low
                let value: Double
                switch mode {
                case .mono: value = (l + r) / 2
                case .cue: value = (l + r) / 2 + Double(parameters.strength) * (side - low)
                case .leftOnly: value = l
                case .rightOnly: value = r
                }
                expected.append(Float(value) * Float(pow(10.0, -18.0 / 20)) * min(1, Float(i) / 4_800))
            }
            XCTAssertEqual(output.count, expected.count)
            XCTAssertLessThan(zip(output, expected).map { abs($0 - $1) }.max() ?? 1, 1e-6)
        }
    }

    func testActualPCMContainerMatrixAndMonoExpansion() throws {
        for ext in ["wav", "aiff"] { for rate in [44_100.0, 48_000.0] {
            for channels in [1, 2] { for bits in [16, 24, 32] {
                let url = try fixture(ext: ext, rate: rate, channels: channels, bits: bits, floating: bits == 32)
                let mono = try collect(prepare(url))
                let cue = try collect(prepare(url, mode: .cue))
                XCTAssertEqual(mono, cue, "\(ext) \(rate) \(channels) \(bits)")
                XCTAssertGreaterThan(mono.map(abs).max() ?? 0, 0.1)
                XCTAssertLessThanOrEqual(abs(Double(mono.count - 240) - 6_013 * 48_000 / rate), 2)
            }}
        }}
    }

    func testAllRatePairsDurationPartitionPeakAndTail() throws {
        for sourceRate in [44_100.0, 48_000.0] { for outputRate in [44_100.0, 48_000.0] {
            let url = try fixture(rate: sourceRate, frames: Int(sourceRate), sample: { i, c in
                i > Int(sourceRate) - 500 ? (c == 0 ? 4 : -2) : Float(sin(Double(i) * 0.49)) * 4
            })
            for mode in [ListeningMode.mono, .cue, .leftOnly, .rightOnly] {
                let whole = try collect(prepare(url, rate: outputRate, mode: mode), block: Int.max)
                let split = try collect(prepare(url, rate: outputRate, mode: mode), block: 17)
                XCTAssertEqual(whole, split)
                let latency = Int(ceil(outputRate * 0.005))
                XCTAssertLessThanOrEqual(abs(whole.count - latency - Int(outputRate)), 2)
                XCTAssertTrue(whole.allSatisfy { $0.isFinite && abs($0) <= Float(pow(10.0, -3.0 / 20)) })
                XCTAssertTrue(whole.prefix(latency).allSatisfy { $0 == 0 })
                XCTAssertGreaterThan(abs(whole.last ?? 0), 0.01)
            }
        }}
    }

    func testShortEmptyAndRepeatedEOF() throws {
        for sourceRate in [44_100.0, 48_000.0] { for outputRate in [44_100.0, 48_000.0] {
            for frames in [0, 1, 17, 1_023, 1_024, 1_025] {
                let pipeline = try prepare(fixture(rate: sourceRate, frames: frames), rate: outputRate)
                let output = try collect(pipeline, block: 1)
                let latency = frames == 0 ? 0 : Int(ceil(outputRate * 0.005))
                XCTAssertLessThanOrEqual(abs(Double(output.count - latency) - Double(frames) * outputRate / sourceRate), 2)
                XCTAssertTrue(try pipeline.read(maxFrames: 1_024).isEmpty)
                XCTAssertTrue(try pipeline.read(maxFrames: 1).isEmpty)
            }
        }}
    }

    func testSeekDiscardsPrefetchTailAndPreservesSettings() throws {
        for rate in [44_100.0, 48_000.0] {
            let url = try fixture(rate: rate, frames: 12_013)
            let pipeline = try prepare(url, rate: rate, mode: .cue, gain: -12)
            _ = try pipeline.read(maxFrames: 19)
            try pipeline.seek(sourceFrame: 4_999)
            let suffix = try fixture(rate: rate, frames: 7_014, sample: { i, _ in Float(sin(Double(i + 4_999) * 0.07)) * 0.2 })
            XCTAssertEqual(try collect(pipeline), try collect(prepare(suffix, rate: rate, mode: .cue, gain: -12)))
            try pipeline.seek(sourceFrame: 12_013)
            XCTAssertTrue(try collect(pipeline).isEmpty)
            pipeline.reset()
            XCTAssertEqual(try collect(pipeline), try collect(prepare(url, rate: rate, mode: .cue, gain: -12)))
            XCTAssertThrowsError(try pipeline.seek(sourceFrame: -1))
            XCTAssertThrowsError(try pipeline.seek(sourceFrame: 12_014))
        }
    }

    func testInvalidSettingsAreRejectedAtomicallyAndMuteIsExplicit() throws {
        let url = try fixture()
        let pipeline = try prepare(url)
        for gain in [Float.nan, .infinity, -.infinity, 0.1] {
            XCTAssertThrowsError(try pipeline.set(mode: .cue, parameters: parameters, gainDB: gain))
        }
        XCTAssertThrowsError(try pipeline.set(mode: .cue, parameters: .init(strength: .nan, cutoffHz: 1_500), gainDB: 0))
        XCTAssertThrowsError(try pipeline.set(mode: .cue, parameters: .init(strength: 0.3, cutoffHz: 799), gainDB: 0))
        XCTAssertEqual(try collect(pipeline), try collect(prepare(url)))
        try pipeline.set(mode: .cue, parameters: parameters, gainDB: nil)
        pipeline.reset()
        XCTAssertTrue(try collect(pipeline).allSatisfy { $0 == 0 })
        XCTAssertThrowsError(try pipeline.read(maxFrames: 0))
        XCTAssertThrowsError(try pipeline.read(maxFrames: -1))
        let mono = try prepare(fixture(channels: 1))
        XCTAssertThrowsError(try mono.set(mode: .leftOnly, parameters: parameters, gainDB: 0))
        XCTAssertThrowsError(try mono.set(mode: .rightOnly, parameters: parameters, gainDB: 0))
    }

    func testRejectsUnsupportedAndCorruptFilesWithoutPathDisclosure() throws {
        var urls = try [fixture(rate: 32_000), fixture(channels: 3), fixture(bits: 32, floating: false), fixture(ext: "caf")]
        let disguised = directory.appendingPathComponent("disguised.wav")
        try FileManager.default.copyItem(at: urls.removeLast(), to: disguised)
        urls.append(disguised)
        let corrupt = directory.appendingPathComponent("corrupt.wav")
        try Data("RIFFbroken".utf8).write(to: corrupt)
        urls.append(corrupt)
        let truncated = try fixture()
        let handle = try FileHandle(forWritingTo: truncated)
        try handle.truncate(atOffset: 120)
        try handle.close()
        urls.append(truncated)
        for url in urls {
            XCTAssertThrowsError(try AudioFilePipeline(url: url, outputRate: 48_000)) { error in
                XCTAssertFalse(String(describing: error).contains(self.directory.path))
            }
        }
        XCTAssertThrowsError(try AudioFilePipeline(url: fixture(), outputRate: 96_000))
    }

    func testNonfiniteDecodeLatchesAndSeekRecovers() throws {
        for sourceRate in [44_100.0, 48_000.0] { for outputRate in [44_100.0, 48_000.0] {
        for value in [Float.nan, .infinity, -.infinity] {
            let url = try fixture(rate: sourceRate, frames: 4_000, sample: { i, _ in i == 1_100 ? value : 0.2 })
            let pipeline = try prepare(url, rate: outputRate)
            XCTAssertThrowsError(try collect(pipeline))
            XCTAssertTrue(pipeline.isFaulted)
            XCTAssertThrowsError(try pipeline.seek(sourceFrame: -1))
            XCTAssertTrue(pipeline.isFaulted)
            XCTAssertThrowsError(try pipeline.read(maxFrames: 1))
            try pipeline.seek(sourceFrame: 2_000)
            XCTAssertFalse(pipeline.isFaulted)
            XCTAssertTrue(try collect(pipeline).allSatisfy(\.isFinite))
            pipeline.reset()
            XCTAssertThrowsError(try collect(pipeline))
        }
        }}
    }

    func testOddIntermediateRIFFChunkRequiresPadding() throws {
        let original = try fixture()
        let bytes = try Data(contentsOf: original)
        for padded in [true, false] {
            var changed = Data(bytes.prefix(12))
            changed.append(contentsOf: Array("JUNK".utf8) + [1, 0, 0, 0, 42])
            if padded { changed.append(0) }
            changed.append(bytes.dropFirst(12))
            let size = UInt32(changed.count - 8)
            changed.replaceSubrange(4..<8, with: (0..<4).map { UInt8(truncatingIfNeeded: size >> ($0 * 8)) })
            let url = directory.appendingPathComponent(padded ? "padded.wav" : "unpadded.wav")
            try changed.write(to: url)
            if padded {
                XCTAssertEqual(try collect(prepare(url)), try collect(prepare(original)))
            } else {
                XCTAssertThrowsError(try AudioFilePipeline(url: url, outputRate: 48_000))
            }
        }
    }


    func testInitialMonoGainAndMidstreamChanges() throws {
        let url = try fixture(frames: 24_000, sample: { _, c in c == 0 ? 0.2 : 0.1 })
        let initial = try AudioFilePipeline(url: url, outputRate: 48_000)
        let output = try collect(initial)
        XCTAssertEqual(output[10_000], 0.15 * Float(pow(10.0, -18.0 / 20)), accuracy: 1e-6)
        let pipeline = try AudioFilePipeline(url: url, outputRate: 48_000)
        for _ in 0..<8 { _ = try pipeline.read(maxFrames: 1_024) }
        try pipeline.set(mode: .leftOnly, parameters: parameters, gainDB: -6)
        let changed = try collect(pipeline)
        XCTAssertEqual(changed[5_000], 0.2 * Float(pow(10.0, -6.0 / 20)), accuracy: 1e-6)
    }

    func testWarningInsideReadRemainsObservableUntilNextRead() throws {
        let url = try fixture(frames: 32_768, sample: { i, channel in
            channel == 1 && i < 28_800 ? -0.2 : 0.2
        })
        let pipeline = try prepare(url)
        for _ in 0..<28 { _ = try pipeline.read(maxFrames: 1_024) }
        XCTAssertFalse(pipeline.cancellationWarning)
        _ = try pipeline.read(maxFrames: 1_024)
        XCTAssertTrue(pipeline.cancellationWarning, "A warning that starts and clears in one read must be observable")
        _ = try pipeline.read(maxFrames: 1_024)
        XCTAssertFalse(pipeline.cancellationWarning, "A cleared condition must not latch forever")
    }

    func testGainChangeRampsForTwentyMillisecondsBeforeFinalGuard() throws {
        let pipeline = try prepare(fixture(frames: 12_000, sample: { _, _ in 0.2 }))
        for _ in 0..<6 { _ = try pipeline.read(maxFrames: 1_024) }
        try pipeline.set(mode: .mono, parameters: parameters, gainDB: -6)
        let first = try pipeline.read(maxFrames: 1_024)
        let second = try pipeline.read(maxFrames: 1_024)
        let changed = first + second
        let target = Float(pow(10.0, -6.0 / 20))
        for index in changed.indices {
            let progress = min(1, max(0, Float(index - 240 + 1) / 960))
            XCTAssertEqual(changed[index], 0.2 * (1 + (target - 1) * progress), accuracy: 1e-6)
        }
        try pipeline.set(mode: .mono, parameters: parameters, gainDB: nil)
        let muted = try pipeline.read(maxFrames: 1_024)
        XCTAssertTrue(muted.prefix(240).allSatisfy { $0 > 0 }, "Only existing limiter lookahead may remain")
        XCTAssertTrue(muted.dropFirst(240).allSatisfy { $0 == 0 }, "Mute must not ramp or require reset")
        pipeline.reset()
        XCTAssertTrue(try collect(pipeline).allSatisfy { $0 == 0 })
    }

    func testCancellationWarningPropagates() throws {
        let pipeline = try prepare(fixture(frames: 40_000, sample: { _, c in c == 0 ? 0.2 : -0.2 }))
        XCTAssertTrue(try collect(pipeline).allSatisfy { $0 == 0 })
        XCTAssertTrue(pipeline.cancellationWarning)
        pipeline.reset()
        XCTAssertFalse(pipeline.cancellationWarning)
    }
}
