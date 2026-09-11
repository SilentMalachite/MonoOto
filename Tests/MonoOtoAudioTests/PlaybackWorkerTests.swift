import Foundation
import XCTest
import MonoOtoCore
import MonoOtoRealtime
@testable import MonoOtoAudio

private final class WorkerProbe: @unchecked Sendable {
    let lock = NSLock()
    var reads = 0
    var readSizes: [Int] = []
    var disposed = false
    let disposedAck = DispatchSemaphore(value: 0)
    var mainThreadAccess = false
    var settings: [PlaybackWorker.Settings] = []
    var pushLimits = [Int]()
    var barrier: PlaybackReadBarrier?
    var failRead = false
    func access() { lock.lock(); mainThreadAccess = mainThreadAccess || Thread.isMainThread; lock.unlock() }
    func limit(_ count: Int) -> Int { lock.lock(); defer { lock.unlock() }; return pushLimits.isEmpty ? count : min(count, pushLimits.removeFirst()) }
}

private final class WorkerSource: PlaybackWorkerSource {
    let metadata: PlaybackWorker.Metadata
    var cancellationWarning = false
    let samples: [Float]
    let probe: WorkerProbe
    var offset = 0
    init(samples: [Float], probe: WorkerProbe, channels: Int = 2) {
        self.samples = samples; self.probe = probe
        metadata = .init(sourceFrameCount: Int64(samples.count), sourceRate: 48_000,
                         channelCount: channels, outputRate: 48_000, latencyFrames: 0)
        probe.access()
    }
    func read(maxFrames: Int) throws -> [Float] {
        probe.access(); probe.lock.lock(); probe.reads += 1; probe.readSizes.append(maxFrames); probe.lock.unlock()
        if let barrier = probe.barrier { probe.barrier = nil; barrier.arriveAndWait() }
        if probe.failRead { throw AudioFilePipelineError.decodeFailed }
        let end = min(offset + maxFrames, samples.count)
        defer { offset = end }
        return Array(samples[offset..<end])
    }
    func set(_ settings: PlaybackWorker.Settings) throws {
        probe.access(); probe.lock.lock(); probe.settings.append(settings); probe.lock.unlock()
    }
    func seek(sourceFrame: Int64) throws { offset = Int(sourceFrame) }
    deinit { probe.access(); probe.lock.lock(); probe.disposed = true; probe.lock.unlock(); probe.disposedAck.signal() }
}

private final class WorkerReleaseRecord: @unchecked Sendable {
    let lock = NSLock()
    var releasedOnMain: Bool?
    func mark() { lock.withLock { releasedOnMain = Thread.isMainThread } }
}
private final class WorkerCapture: @unchecked Sendable {
    let record: WorkerReleaseRecord
    init(_ record: WorkerReleaseRecord) { self.record = record }
    deinit { record.mark() }
}

@MainActor final class PlaybackWorkerTests: XCTestCase {
    private func drain(_ owner: PlaybackRenderOwner, count: Int) -> [Float] {
        let before = owner.stats.rendered_frames
        var left = [Float](repeating: -1, count: count), right = left
        left.withUnsafeMutableBufferPointer { l in right.withUnsafeMutableBufferPointer { r in
            _ = mo_queue_render(owner.queue, .init(data: l.baseAddress, capacity: UInt32(count)),
                                .init(data: r.baseAddress, capacity: UInt32(count)), UInt32(count))
        } }
        XCTAssertTrue(right.allSatisfy { $0 == 0 })
        return Array(left.prefix(Int(owner.stats.rendered_frames - before)))
    }
    private func worker(_ samples: [Float], owner: PlaybackRenderOwner, probe: WorkerProbe) -> PlaybackWorker {
        PlaybackWorker(sessionID: 9, owner: owner, automaticTicks: false,
            sourceFactory: { WorkerSource(samples: samples, probe: probe) },
            push: { queue, samples in
                let count = probe.limit(samples.count)
                return mo_queue_push(queue, samples.baseAddress, UInt32(count))
            })
    }
    func testPartialPushZeroOneRemainderPreservesEveryPCM() async throws {
        let owner = try PlaybackRenderOwner(ear: .left), probe = WorkerProbe()
        probe.pushLimits = [0, 1, 5]
        let samples = (0..<17).map { Float($0) / 100 }
        let worker = worker(samples, owner: owner, probe: probe)
        _ = try await worker.prepare(prefill: false)
        await worker.resume(ticket: 1)
        var actual: [Float] = []
        for _ in 0..<12 { await worker.tickForTesting(); actual += drain(owner, count: 4) }
        XCTAssertEqual(actual.map(\.bitPattern), samples.map(\.bitPattern))
        XCTAssertTrue(worker.snapshot().producerDone)
        XCTAssertEqual(worker.snapshot().totalAccepted, 17)
        await worker.stop()
        XCTAssertTrue(probe.disposed)
        XCTAssertFalse(probe.mainThreadAccess)
    }
    func testQueueAndPendingBudgetRemainsBoundedWithoutConsumer() async throws {
        let owner = try PlaybackRenderOwner(ear: .left), probe = WorkerProbe()
        let worker = worker([Float](repeating: 0.2, count: 20_000), owner: owner, probe: probe)
        _ = try await worker.prepare(prefill: false); await worker.resume(ticket: 1)
        for _ in 0..<100 { await worker.tickForTesting() }
        let snapshot = worker.snapshot()
        XCTAssertEqual(snapshot.totalAccepted, 4096)
        XCTAssertLessThanOrEqual(snapshot.totalAccepted - owner.stats.rendered_frames + UInt64(snapshot.pendingCount), 4096)
        XCTAssertTrue(probe.readSizes.allSatisfy { $0 > 0 && $0 <= 1024 })
        XCTAssertEqual(probe.reads, 4)
        await worker.stop()
    }
    func testParkPreservesPendingAndStopsReadUntilResume() async throws {
        let owner = try PlaybackRenderOwner(ear: .left), probe = WorkerProbe()
        probe.pushLimits = [1]
        let samples = (0..<1025).map { Float($0 % 31) / 100 }
        let worker = worker(samples, owner: owner, probe: probe)
        _ = try await worker.prepare(prefill: false); await worker.resume(ticket: 1)
        await worker.tickForTesting()
        worker.requestPark(ticket: 2); await worker.park(ticket: 2)
        let before = worker.snapshot(), reads = probe.reads
        for _ in 0..<5 { await worker.tickForTesting() }
        XCTAssertEqual(worker.snapshot().pendingCount, before.pendingCount)
        XCTAssertEqual(probe.reads, reads)
        XCTAssertEqual(worker.snapshot().parkedTicket, 2)
        var actual = drain(owner, count: 10)
        await worker.resume(ticket: 3)
        for _ in 0..<10 { await worker.tickForTesting(); actual += drain(owner, count: 512) }
        XCTAssertEqual(actual.map(\.bitPattern), samples.map(\.bitPattern))
        await worker.stop()
    }
    func testLatestSettingsMailboxRejectsInvalidAtomically() async throws {
        let owner = try PlaybackRenderOwner(ear: .left), probe = WorkerProbe()
        let worker = worker([Float](repeating: 0.1, count: 5000), owner: owner, probe: probe)
        _ = try await worker.prepare(prefill: false)
        for index in 0..<1000 {
            try worker.updateSettings(.init(mode: .cue, parameters: .init(strength: Float(index % 6) / 10, cutoffHz: 2000), gainDB: -12))
        }
        XCTAssertThrowsError(try worker.updateSettings(.init(mode: .mono, parameters: .init(strength: .nan, cutoffHz: 1000), gainDB: -12)))
        await worker.resume(ticket: 1); await worker.tickForTesting()
        XCTAssertEqual(probe.settings.count, 2)
        XCTAssertEqual(probe.settings.last?.mode, .cue)
        await worker.stop()
    }
    func testStopDuringReadDiscardsResultAndAcknowledgesWithoutStopAwait() async throws {
        let owner = try PlaybackRenderOwner(ear: .left), probe = WorkerProbe()
        let barrier = PlaybackReadBarrier(); probe.barrier = barrier
        let worker = worker([Float](repeating: 0.2, count: 2048), owner: owner, probe: probe)
        _ = try await worker.prepare(prefill: false); await worker.resume(ticket: 1)
        let read = Task.detached { await worker.tickForTesting() }
        XCTAssertTrue(barrier.waitForArrival())
        worker.requestStop()
        XCTAssertTrue(owner.stats.silenced)
        XCTAssertFalse(worker.snapshot().finished)
        barrier.resume(); await read.value
        await worker.tickForTesting() // queued after the cleanup, an explicit barrier
        XCTAssertTrue(worker.snapshot().finished)
        XCTAssertEqual(worker.snapshot().totalAccepted, 0)
        XCTAssertTrue(probe.disposed)
        XCTAssertFalse(probe.mainThreadAccess)
    }
    func testParkDuringReadKeepsUnpushedResultThenResumesExactly() async throws {
        let owner = try PlaybackRenderOwner(ear: .left), probe = WorkerProbe()
        let barrier = PlaybackReadBarrier(); probe.barrier = barrier
        let samples = (0..<1025).map { Float($0 % 29) / 100 }
        let worker = worker(samples, owner: owner, probe: probe)
        _ = try await worker.prepare(prefill: false); await worker.resume(ticket: 1)
        let read = Task.detached { await worker.tickForTesting() }
        XCTAssertTrue(barrier.waitForArrival())
        worker.requestPark(ticket: 2)
        barrier.resume(); await read.value; await worker.park(ticket: 2)
        XCTAssertEqual(worker.snapshot().pendingCount, 1024)
        XCTAssertEqual(worker.snapshot().totalAccepted, 0)
        await worker.resume(ticket: 3)
        var actual: [Float] = []
        for _ in 0..<8 { await worker.tickForTesting(); actual += drain(owner, count: 513) }
        XCTAssertEqual(actual.map(\.bitPattern), samples.map(\.bitPattern))
        await worker.stop()
    }
    func testDecodeFailureAndNonfiniteInputSilenceBeforeControlDelivery() async throws {
        for decodeFailure in [false, true] {
            let owner = try PlaybackRenderOwner(ear: .left), probe = WorkerProbe()
            probe.failRead = decodeFailure
            let worker = worker([0.2, .nan], owner: owner, probe: probe)
            _ = try await worker.prepare(prefill: false); await worker.resume(ticket: 1)
            await worker.tickForTesting()
            XCTAssertTrue(owner.stats.silenced)
            XCTAssertTrue(worker.snapshot().finished)
            XCTAssertNotNil(worker.snapshot().error)
            XCTAssertEqual(worker.snapshot().totalAccepted, 0)
            await worker.resume(ticket: 2)
            XCTAssertTrue(owner.stats.silenced)
        }
    }
    func testEOFTailAllFourRatePairsAndBoundaryLengths() async throws {
        let fixture = try PlaybackFixture()
        let settings = PlaybackWorker.Settings(mode: .cue, parameters: .init(strength: 0.35, cutoffHz: 1500), gainDB: -18)
        for sourceRate in [44_100.0, 48_000.0] {
            for outputRate in [44_100.0, 48_000.0] {
                for frames in [0, 1, 17, 1023, 1024, 1025] {
                    let url = try fixture.wav(rate: sourceRate, frames: frames)
                    let expected = try fixture.collect(fixture.pipeline(url, outputRate: outputRate))
                    let owner = try PlaybackRenderOwner(ear: .left)
                    let worker = PlaybackWorker(sessionID: 1, owner: owner, settings: settings,
                        automaticTicks: false, factory: { try AudioFilePipeline(url: url, outputRate: outputRate) })
                    let metadata = try await worker.prepare(prefill: false)
                    XCTAssertEqual(metadata.sourceFrameCount, Int64(frames))
                    await worker.resume(ticket: 1)
                    var actual: [Float] = []
                    for _ in 0..<100 {
                        await worker.tickForTesting(); actual += drain(owner, count: 137)
                        if worker.snapshot().producerDone && owner.stats.rendered_frames == worker.snapshot().totalAccepted { break }
                    }
                    XCTAssertTrue(worker.snapshot().producerDone)
                    XCTAssertEqual(actual.map(\.bitPattern), expected.map(\.bitPattern), "\(sourceRate) -> \(outputRate), \(frames)")
                    let total = worker.snapshot().totalAccepted
                    for _ in 0..<3 { await worker.tickForTesting() }
                    XCTAssertEqual(worker.snapshot().totalAccepted, total)
                    await worker.stop()
                }
            }
        }
    }
    func testAutomaticPrefillReadyIncludesEmptyAndShortEOF() async throws {
        for frames in [0, 17, 5000] {
            let owner = try PlaybackRenderOwner(ear: .left), probe = WorkerProbe()
            let worker = PlaybackWorker(sessionID: 1, owner: owner,
                sourceFactory: { WorkerSource(samples: [Float](repeating: 0.1, count: frames), probe: probe) })
            _ = try await worker.prepare()
            let snapshot = worker.snapshot()
            XCTAssertTrue(snapshot.ready)
            XCTAssertTrue(snapshot.totalAccepted >= 2048 || snapshot.producerDone)
            await worker.stop()
        }
    }

    func testOlderResumeCannotClearNewerParkRequest() async throws {
        let owner = try PlaybackRenderOwner(ear: .left), probe = WorkerProbe()
        let worker = worker([0.1, 0.2], owner: owner, probe: probe)
        _ = try await worker.prepare(prefill: false)
        await worker.park(ticket: 10)
        await worker.resume(ticket: 9)
        await worker.tickForTesting()
        XCTAssertTrue(worker.snapshot().parked)
        XCTAssertEqual(worker.snapshot().parkedTicket, 10)
        XCTAssertEqual(worker.snapshot().totalAccepted, 0)
        await worker.stop()
    }
    func testMonoSettingRejectionPreservesPreviousSnapshot() async throws {
        let owner = try PlaybackRenderOwner(ear: .left), probe = WorkerProbe()
        let worker = PlaybackWorker(sessionID: 1, owner: owner, automaticTicks: false,
            sourceFactory: { WorkerSource(samples: [0.1, 0.2], probe: probe, channels: 1) })
        _ = try await worker.prepare(prefill: false)
        try worker.updateSettings(.init(mode: .cue, parameters: .init(strength: 0.2, cutoffHz: 2000), gainDB: nil))
        XCTAssertThrowsError(try worker.updateSettings(.init(mode: .leftOnly, parameters: .init(strength: 0.4, cutoffHz: 1800), gainDB: 0)))
        await worker.resume(ticket: 1); await worker.tickForTesting()
        XCTAssertEqual(probe.settings.last?.mode, .cue)
        XCTAssertNil(probe.settings.last?.gainDB)
        await worker.stop()
    }
    func testAbandonedWorkerReleasesSourceOnDedicatedQueue() async throws {
        let owner = try PlaybackRenderOwner(ear: .left), probe = WorkerProbe()
        var worker: PlaybackWorker? = self.worker([0.1], owner: owner, probe: probe)
        _ = try await worker!.prepare(prefill: false)
        worker = nil
        XCTAssertEqual(probe.disposedAck.wait(timeout: .now() + 5), .success)
        XCTAssertFalse(probe.mainThreadAccess)
        XCTAssertTrue(owner.stats.silenced)
    }

    func testEOFFactSurvivesParkArrivingDuringFinalRead() async throws {
        let owner = try PlaybackRenderOwner(ear: .left), probe = WorkerProbe()
        let barrier = PlaybackReadBarrier(); probe.barrier = barrier
        let worker = worker([], owner: owner, probe: probe)
        _ = try await worker.prepare(prefill: false); await worker.resume(ticket: 1)
        let read = Task.detached { await worker.tickForTesting() }
        XCTAssertTrue(barrier.waitForArrival())
        worker.requestPark(ticket: 2)
        barrier.resume(); await read.value; await worker.park(ticket: 2)
        XCTAssertTrue(worker.snapshot().producerDone)
        XCTAssertEqual(worker.snapshot().totalAccepted, 0)
        XCTAssertTrue(worker.snapshot().parked)
        await worker.stop()
    }

    func testFinishedDoesNotAcknowledgeWhileProducerClosureStillOwnsWorker() async throws {
        for timerFailure in [false, true] {
            let owner = try PlaybackRenderOwner(ear: .left), probe = WorkerProbe()
            probe.failRead = timerFailure
            let barrier = PlaybackReadBarrier(), record = WorkerReleaseRecord()
            func makeWorker() -> PlaybackWorker {
                let capture = WorkerCapture(record)
                return PlaybackWorker(sessionID: 1, owner: owner, automaticTicks: timerFailure,
                    sourceFactory: { withExtendedLifetime(capture) { WorkerSource(samples: [0.1], probe: probe) } },
                    afterFinishedForTesting: { barrier.arriveAndWait() })
            }
            var worker: PlaybackWorker? = makeWorker()
            _ = try await worker!.prepare(prefill: false)
            if timerFailure { await worker!.resume(ticket: 1) }
            else { worker!.requestStop() }
            XCTAssertTrue(barrier.waitForArrival())
            XCTAssertTrue(worker!.snapshot().finished)
            XCTAssertFalse(worker!.completionConfirmed, "finished precedes the producer closure's final release")
            barrier.resume()
            let deadline = ContinuousClock.now + .seconds(5)
            while !worker!.completionConfirmed, ContinuousClock.now < deadline { await Task.yield() }
            XCTAssertTrue(worker!.completionConfirmed)
            // No queued operations may be recreated after completion has been proved.
            for _ in 0..<1000 { worker!.requestStop(); worker!.requestPark(ticket: 9) }
            await worker!.resume(ticket: 10)
            XCTAssertTrue(worker!.completionConfirmed)
            worker = nil
            XCTAssertEqual(record.lock.withLock { record.releasedOnMain }, true)
        }
    }

}
