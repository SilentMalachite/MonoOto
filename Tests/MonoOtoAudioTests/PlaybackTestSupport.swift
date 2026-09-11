import AVFoundation
import Foundation
import MonoOtoCore
import MonoOtoRealtime
@testable import MonoOtoAudio

/// Deterministic, generated PCM only; no user file or physical output is used.
final class PlaybackFixture {
    let directory: URL
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: directory) }

    func wav(rate: Double, frames: Int = 12_013, channels: Int = 2) throws -> URL {
        let url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate,
            AVNumberOfChannelsKey: channels, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false])
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                      frameCapacity: AVAudioFrameCount(max(1, frames)))!
        buffer.frameLength = AVAudioFrameCount(frames)
        var seed: UInt32 = 0x12345678
        for i in 0..<frames {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let noise = Float(Int32(bitPattern: seed)) / Float(Int32.max) * 0.25
            let left: Float = i % 997 == 0 || i == frames - 1 ? 0.65 : noise
            // Exact silence, inverse phase, and broadband nonzero material coexist.
            buffer.floatChannelData![0][i] = (2_000..<2_500).contains(i) ? 0 : left
            if channels == 2 {
                buffer.floatChannelData![1][i] = (2_000..<2_500).contains(i) ? 0 :
                    ((4_000..<6_000).contains(i) ? -left : left * 0.37)
            }
        }
        if frames > 0 { try file.write(from: buffer) }
        return url
    }

    func pipeline(_ url: URL, outputRate: Double) throws -> AudioFilePipeline {
        let pipeline = try AudioFilePipeline(url: url, outputRate: outputRate)
        try pipeline.set(mode: .cue, parameters: .init(strength: 0.35, cutoffHz: 1_500), gainDB: -18)
        pipeline.reset()
        return pipeline
    }

    func collect(_ pipeline: AudioFilePipeline) throws -> [Float] {
        var result: [Float] = []
        for _ in 0..<100_000 {
            let part = try pipeline.read(maxFrames: 137)
            if part.isEmpty { return result }
            result += part
        }
        throw PlaybackSupportError.didNotReachEOF
    }
}

enum PlaybackSupportError: Error { case queueCreationFailed, didNotReachEOF }

/// Single-thread test driver. A held sink makes no render call. Only the queue's
/// rendered_frames delta identifies original PCM, including actual zero samples.
final class PlaybackManualSink {
    let queue: OpaquePointer
    private(set) var originalPCM: [Float] = []
    var held = false
    init(capacity: UInt32 = 64) throws {
        guard let queue = mo_queue_create(capacity, 0) else { throw PlaybackSupportError.queueCreationFailed }
        self.queue = queue
    }
    deinit { mo_queue_destroy(queue) }
    var consumed: UInt64 { mo_queue_read_stats(queue).rendered_frames }
    func push(_ samples: [Float], offset: Int) -> Int {
        samples.withUnsafeBufferPointer {
            Int(mo_queue_push(queue, $0.baseAddress!.advanced(by: offset), UInt32(samples.count - offset)))
        }
    }
    @discardableResult func render(_ count: Int) -> [Float] {
        guard !held else { return [Float](repeating: 0, count: count) }
        let before = consumed
        var left = [Float](repeating: 0, count: count)
        var right = left
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                _ = mo_queue_render(queue, MOFloatBuffer(data: l.baseAddress, capacity: UInt32(count)),
                                    MOFloatBuffer(data: r.baseAddress, capacity: UInt32(count)), UInt32(count))
            }
        }
        originalPCM.append(contentsOf: left.prefix(Int(consumed - before)))
        return left
    }
}

/// Worker tests place arriveAndWait() at a read entry/exit. The test waits for an
/// explicit acknowledgement then releases it; timeout is failure detection only.
final class PlaybackReadBarrier: @unchecked Sendable {
    private let arrived = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    func arriveAndWait() { arrived.signal(); release.wait() }
    func waitForArrival(timeout: DispatchTime = .now() + 5) -> Bool {
        arrived.wait(timeout: timeout) == .success
    }
    func resume() { release.signal() }
}

struct PlaybackManualClock {
    private(set) var now: Duration = .zero
    mutating func advance(by duration: Duration) { precondition(duration >= .zero); now += duration }
}

@MainActor final class PlaybackTestBackend: DeviceOutputBackend {
    var callbackCount: UInt64 { 0 }
    var devices = [OutputDevice(uid: "test", name: "Test", sampleRate: 48_000, channels: 2, deviceID: 42)]
    var starts = 0
    var renderCompletionConfirmed = true
    var drainDuration: TimeInterval { 0.02 }
    var configureHook: (() async -> Void)?
    var owner: PlaybackRenderOwner?
    var handler: (@MainActor @Sendable (DeviceOutputEvent) -> Void)?
    func availableDevices() throws -> [OutputDevice] { devices }
    func configure(device: OutputDevice, sampleRate: Double, renderOwner: PlaybackRenderOwner?,
                   onEvent: @escaping @MainActor @Sendable (DeviceOutputEvent) -> Void) async throws {
        owner = renderOwner; handler = onEvent
        await configureHook?()
    }
    func snapshot() throws -> DeviceOutputSnapshot {
        DeviceOutputSnapshot(deviceID: 42, sampleRate: devices[0].sampleRate, channels: 2, isStereo: true)
    }
    func start() throws { starts += 1 }
    func stop() {}
    func dispose() { owner = nil }
    func resetDiagnostics() {}
}

@MainActor extension PlaybackTestBackend {
    func render(_ count: Int, ear: HearingEar) -> (pcm: [Float], other: [Float], consumed: Int) {
        guard let owner else { return ([], [], 0) }
        let before = owner.stats.rendered_frames
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
        buffer.frameLength = AVAudioFrameCount(count)
        var silent = false
        _ = mo_render_context_render(owner.context, buffer.mutableAudioBufferList, UInt32(count), &silent)
        let selected = ear == .left ? 0 : 1
        return (Array(UnsafeBufferPointer(start: buffer.floatChannelData![selected], count: count)),
                Array(UnsafeBufferPointer(start: buffer.floatChannelData![1 - selected], count: count)),
                Int(owner.stats.rendered_frames - before))
    }
}

@MainActor final class PlaybackControllerClock { var now = 0.0 }

final class PlaybackPreparationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = false
    let barrier = PlaybackReadBarrier()
    func arm() { lock.withLock { armed = true } }
    func enterIfArmed() {
        let blocked = lock.withLock { let value = armed; armed = false; return value }
        if blocked { barrier.arriveAndWait() }
    }
}
