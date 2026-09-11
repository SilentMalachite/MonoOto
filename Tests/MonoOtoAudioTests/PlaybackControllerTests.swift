import XCTest
import MonoOtoCore
@testable import MonoOtoAudio
import MonoOtoRealtime

/// 6.1 contract tests use existing Pipeline/queue APIs. Controller lifecycle,
/// concurrent hold acknowledgement, and hardware continuity are separate gates.
final class PlaybackControllerTests: XCTestCase {
    func testPauseResumePreservesNormalPCM() throws {
        let fixture = try PlaybackFixture()
        for sourceRate in [44_100.0, 48_000.0] {
            let url = try fixture.wav(rate: sourceRate)
            for outputRate in [44_100.0, 48_000.0] {
                let reference = try fixture.collect(fixture.pipeline(url, outputRate: outputRate))
                for pauseAt in [17, reference.count / 2, reference.count - 17] {
                    let pipeline = try fixture.pipeline(url, outputRate: outputRate)
                    let sink = try PlaybackManualSink()
                    var pending: [Float] = []
                    var offset = 0
                    var ended = false
                    var paused = false
                    var totalAccepted = 0
                    var completed = false
                    for _ in 0..<100_000 {
                        if offset == pending.count && !ended {
                            pending = try pipeline.read(maxFrames: 1_024)
                            offset = 0
                            ended = pending.isEmpty
                        }
                        if offset < pending.count {
                            let accepted = sink.push(pending, offset: offset)
                            offset += accepted
                            totalAccepted += accepted
                        }
                        if !paused && sink.consumed == UInt64(pauseAt) {
                            let before = sink.consumed
                            let pendingBits = pending.map(\.bitPattern)
                            let retainedOffset = offset
                            sink.held = true
                            XCTAssertEqual(sink.render(31), [Float](repeating: 0, count: 31))
                            XCTAssertEqual(sink.consumed, before)
                            XCTAssertEqual(pending.map(\.bitPattern), pendingBits)
                            XCTAssertEqual(offset, retainedOffset)
                            if pauseAt == 17 {
                                XCTAssertGreaterThan(pending.count - offset, 0, "Unpushed PCM must exist")
                                XCTAssertGreaterThan(offset - Int(sink.consumed), 0, "Queued PCM must exist")
                            }
                            // Retain pipeline, queue, pending block and offset. No seek/reset.
                            sink.held = false
                            paused = true
                        }
                        if ended && sink.consumed == UInt64(totalAccepted) { completed = true; break }
                        let request = paused ? 31 : min(31, pauseAt - Int(sink.consumed))
                        sink.render(request)
                    }
                    XCTAssertTrue(completed, "EOF must drain within the bounded test driver")
                    XCTAssertTrue(paused)
                    let actual = sink.originalPCM.map(\.bitPattern)
                    let expected = reference.map(\.bitPattern)
                    XCTAssertTrue(actual == expected,
                                  "\(sourceRate)→\(outputRate), pause=\(pauseAt), counts \(actual.count)/\(expected.count), first mismatch=\(zip(actual, expected).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? -1)")
                }
            }
        }
    }

    func testSeekBasedResumeDoesNotPreserveProcessingHistory() throws {
        let fixture = try PlaybackFixture()
        for sourceRate in [44_100.0, 48_000.0] {
            let url = try fixture.wav(rate: sourceRate)
            for outputRate in [44_100.0, 48_000.0] {
                let reference = try fixture.collect(fixture.pipeline(url, outputRate: outputRate))
                let boundary = 6_000
                let resumed = try fixture.pipeline(url, outputRate: outputRate)
                var prefix: [Float] = []
                while prefix.count < boundary {
                    prefix += try resumed.read(maxFrames: min(1_024, boundary - prefix.count))
                }
                XCTAssertEqual(prefix.map(\.bitPattern), reference.prefix(boundary).map(\.bitPattern))
                try resumed.seek(sourceFrame: Int64(Double(boundary) * sourceRate / outputRate))
                let suffix = try fixture.collect(resumed)
                let expected = Array(reference.dropFirst(boundary))
                XCTAssertTrue(expected.contains { $0 != 0 }, "Diagnostic must contain nonzero PCM")
                XCTAssertFalse(suffix.map(\.bitPattern) == expected.map(\.bitPattern),
                               "Seek cannot restore SRC, DSP, limiter and fade history")
            }
        }
    }

    func testReadBarrierAcknowledgesBeforeResumeWithoutSleep() {
        let barrier = PlaybackReadBarrier()
        let finished = expectation(description: "released read")
        DispatchQueue.global().async {
            barrier.arriveAndWait()
            finished.fulfill()
        }
        let arrived = barrier.waitForArrival()
        // Always release, including assertion failure, so a failed test leaves no worker blocked.
        barrier.resume()
        XCTAssertTrue(arrived)
        wait(for: [finished], timeout: 5)
        var clock = PlaybackManualClock()
        clock.advance(by: .milliseconds(20))
        XCTAssertEqual(clock.now, .milliseconds(20))
    }

    func testManualSinkCountsSourceZerosButExcludesUnderrunAndHoldPadding() throws {
        let sink = try PlaybackManualSink()
        XCTAssertEqual(sink.push([0, 0.1, 0], offset: 0), 3)
        sink.held = true
        XCTAssertEqual(sink.render(5), [Float](repeating: 0, count: 5))
        XCTAssertEqual(sink.consumed, 0)
        sink.held = false
        sink.render(5)
        XCTAssertEqual(sink.originalPCM, [0, 0.1, 0])
        XCTAssertEqual(sink.consumed, 3)
        XCTAssertEqual(mo_queue_read_stats(sink.queue).underruns, 1)
    }
}

extension PlaybackControllerTests {
    @MainActor func testOpenDoesNotStartOutputAndStopResetsPosition() async throws {
        let fixture = try PlaybackFixture()
        let backend = PlaybackTestBackend()
        let controller = PlaybackController(output: DeviceOutput(backend: backend), devices: { backend.devices })
        try await controller.open(url: fixture.wav(rate: 48_000))
        XCTAssertEqual(controller.phase, .stopped)
        XCTAssertEqual(controller.channelCount, 2)
        XCTAssertGreaterThan(controller.durationSeconds, 0)
        XCTAssertEqual(backend.starts, 0)
        controller.selectOutput(uid: "test", ear: .left)
        await controller.waitUntilSettled()
        try await controller.play()
        XCTAssertEqual(controller.phase, .running)
        XCTAssertEqual(backend.starts, 1)
        controller.stop()
        XCTAssertEqual(controller.phase, .stopping)
        await controller.waitUntilSettled()
        XCTAssertEqual(controller.phase, .stopped)
        XCTAssertEqual(controller.positionSeconds, 0)
    }

    @MainActor func testPlayRequiresExplicitFileDeviceAndEarSelection() async throws {
        let fixture = try PlaybackFixture()
        let backend = PlaybackTestBackend()
        let controller = PlaybackController(output: DeviceOutput(backend: backend), devices: { backend.devices })
        do { try await controller.play(); XCTFail("No file or selection") } catch {}
        try await controller.open(url: fixture.wav(rate: 48_000))
        do { try await controller.play(); XCTFail("No explicit output and ear") } catch {}
        XCTAssertEqual(backend.starts, 0)
        XCTAssertEqual(controller.phase, .stopped)
    }

    @MainActor func testStopDuringPreparationCannotResurrectOutput() async throws {
        let fixture = try PlaybackFixture()
        let backend = PlaybackTestBackend()
        let controller = PlaybackController(output: DeviceOutput(backend: backend), devices: { backend.devices })
        try await controller.open(url: fixture.wav(rate: 48_000))
        controller.selectOutput(uid: "test", ear: .right)
        await controller.waitUntilSettled()
        let entered = expectation(description: "configure entered")
        var release: CheckedContinuation<Void, Never>?
        backend.configureHook = {
            await withCheckedContinuation { release = $0; entered.fulfill() }
        }
        let start = Task { try await controller.play() }
        await fulfillment(of: [entered], timeout: 3)
        controller.stop()
        release?.resume()
        _ = try? await start.value
        await controller.waitUntilSettled()
        XCTAssertEqual(controller.phase, .stopped)
        XCTAssertEqual(backend.starts, 0)
    }
}

extension PlaybackControllerTests {
    @MainActor func testActualControllerPausePreservesPipelineAndQueuedPCM() async throws {
        let fixture = try PlaybackFixture()
        for sourceRate in [44_100.0, 48_000.0] {
            let url = try fixture.wav(rate: sourceRate)
            for outputRate in [44_100.0, 48_000.0] {
                let backend = PlaybackTestBackend()
                backend.devices = [.init(uid: "test", name: "Test", sampleRate: outputRate, channels: 2, deviceID: 42)]
                let controller = PlaybackController(output: DeviceOutput(backend: backend), devices: { backend.devices }, automaticPolling: false)
                try await controller.open(url: url)
                try controller.set(mode: .cue, parameters: .init(strength: 0.35, cutoffHz: 1_500), gainDB: -18)
                controller.selectOutput(uid: "test", ear: .right)
                await controller.waitUntilSettled()
                try await controller.play()
                let owner = try XCTUnwrap(backend.owner)
                let expected = try fixture.collect(fixture.pipeline(url, outputRate: outputRate))
                let first = backend.render(17, ear: .right)
                var actual = Array(first.pcm.prefix(first.consumed))
                controller.pause()
                await controller.waitUntilSettled()
                XCTAssertEqual(controller.phase, .paused)
                let held = backend.render(37, ear: .right)
                XCTAssertEqual(held.consumed, 0)
                XCTAssertTrue(held.pcm.allSatisfy { $0 == 0 })
                try await controller.play()
                XCTAssertTrue(owner === backend.owner)
                for _ in 0..<1_000 {
                    if actual.count == expected.count { break }
                    let part = backend.render(min(127, expected.count - actual.count), ear: .right)
                    XCTAssertTrue(part.other.allSatisfy { $0 == 0 })
                    actual.append(contentsOf: part.pcm.prefix(part.consumed))
                    try await Task.sleep(for: .milliseconds(2))
                }
                XCTAssertEqual(actual.map(\.bitPattern), expected.map(\.bitPattern))
                controller.stop(); await controller.waitUntilSettled()
            }
        }
    }

    @MainActor func testStopThenPlayAndDoubleStopNeverDisposeNewSession() async throws {
        let fixture = try PlaybackFixture()
        let backend = PlaybackTestBackend()
        let controller = PlaybackController(output: DeviceOutput(backend: backend), devices: { backend.devices }, automaticPolling: false)
        try await controller.open(url: fixture.wav(rate: 48_000))
        controller.selectOutput(uid: "test", ear: .left); await controller.waitUntilSettled()
        try await controller.play()
        let old = try XCTUnwrap(backend.owner)
        controller.stop(); controller.stop()
        try await controller.play()
        XCTAssertEqual(controller.phase, .running)
        XCTAssertFalse(old === backend.owner)
        XCTAssertTrue(old.stats.silenced)
        XCTAssertEqual(backend.starts, 2)
        controller.stop(); await controller.waitUntilSettled()
    }

    @MainActor func testImmediatePausePlayRetainsSession() async throws {
        let fixture = try PlaybackFixture()
        let backend = PlaybackTestBackend()
        let controller = PlaybackController(output: DeviceOutput(backend: backend), devices: { backend.devices }, automaticPolling: false)
        try await controller.open(url: fixture.wav(rate: 48_000))
        controller.selectOutput(uid: "test", ear: .left); await controller.waitUntilSettled()
        try await controller.play()
        let owner = try XCTUnwrap(backend.owner)
        controller.pause()
        try await controller.play()
        XCTAssertEqual(controller.phase, .running)
        XCTAssertTrue(owner === backend.owner)
        controller.stop(); await controller.waitUntilSettled()
    }

    @MainActor func testLatestOpenReplacesInFlightPreparation() async throws {
        let fixture = try PlaybackFixture()
        let backend = PlaybackTestBackend()
        let controller = PlaybackController(output: DeviceOutput(backend: backend), devices: { backend.devices }, automaticPolling: false)
        try await controller.open(url: fixture.wav(rate: 48_000))
        controller.selectOutput(uid: "test", ear: .left); await controller.waitUntilSettled()
        let entered = expectation(description: "configure blocked")
        var release: CheckedContinuation<Void, Never>?
        backend.configureHook = { await withCheckedContinuation { release = $0; entered.fulfill() } }
        let start = Task { try await controller.play() }
        await fulfillment(of: [entered], timeout: 3)
        let a = try fixture.wav(rate: 48_000, frames: 24_000)
        let b = try fixture.wav(rate: 44_100, frames: 44_100)
        let first = Task { try await controller.open(url: a) }
        await Task.yield()
        let second = Task { try await controller.open(url: b) }
        await Task.yield()
        release?.resume()
        _ = try? await start.value
        _ = try? await first.value
        try await second.value
        XCTAssertEqual(controller.durationSeconds, 1)
        XCTAssertEqual(controller.phase, .stopped)
        XCTAssertEqual(backend.starts, 0)
    }

    @MainActor func testPausedFaultNeverResumesAndErrorPersists() async throws {
        let fixture = try PlaybackFixture()
        let backend = PlaybackTestBackend()
        let controller = PlaybackController(output: DeviceOutput(backend: backend), devices: { backend.devices }, automaticPolling: false)
        try await controller.open(url: fixture.wav(rate: 48_000))
        controller.selectOutput(uid: "test", ear: .left); await controller.waitUntilSettled()
        try await controller.play(); controller.pause(); await controller.waitUntilSettled()
        backend.handler?(.sleep)
        await controller.waitUntilSettled()
        XCTAssertEqual(controller.phase, .stopped)
        XCTAssertNotNil(controller.lastError)
        XCTAssertEqual(backend.starts, 1)
        XCTAssertNil(backend.owner)
    }

    @MainActor func testEOFWaitsForInjectedDrainDeadline() async throws {
        let fixture = try PlaybackFixture()
        let backend = PlaybackTestBackend()
        let clock = PlaybackControllerClock()
        let controller = PlaybackController(output: DeviceOutput(backend: backend), devices: { backend.devices }, now: { clock.now }, automaticPolling: false)
        try await controller.open(url: fixture.wav(rate: 48_000, frames: 17))
        controller.selectOutput(uid: "test", ear: .left); await controller.waitUntilSettled()
        try await controller.play()
        XCTAssertEqual(backend.render(257, ear: .left).consumed, 257)
        controller.pollForTesting()
        XCTAssertEqual(controller.phase, .running)
        XCTAssertEqual(backend.render(31, ear: .left).consumed, 0)
        clock.now = 0.019; controller.pollForTesting()
        XCTAssertEqual(controller.phase, .running)
        clock.now = 0.021; controller.pollForTesting()
        await controller.waitUntilSettled()
        XCTAssertEqual(controller.phase, .stopped)
        XCTAssertNil(backend.owner)
    }

    @MainActor func testStallUsesInjectedClockAndPauseDoesNotAgeDeadline() async throws {
        let fixture = try PlaybackFixture()
        let backend = PlaybackTestBackend()
        let clock = PlaybackControllerClock()
        let controller = PlaybackController(output: DeviceOutput(backend: backend), devices: { backend.devices }, now: { clock.now }, automaticPolling: false)
        try await controller.open(url: fixture.wav(rate: 48_000))
        controller.selectOutput(uid: "test", ear: .left); await controller.waitUntilSettled()
        try await controller.play(); controller.pause(); await controller.waitUntilSettled()
        clock.now = 10; controller.pollForTesting()
        XCTAssertEqual(controller.phase, .paused)
        try await controller.play()
        clock.now = 10.49; controller.pollForTesting()
        XCTAssertEqual(controller.phase, .running)
        clock.now = 10.51; controller.pollForTesting()
        await controller.waitUntilSettled()
        XCTAssertEqual(controller.phase, .stopped)
        XCTAssertNotNil(controller.lastError)
    }

    @MainActor func testInvalidSettingsSeekAndConfirmationRemainExplicit() async throws {
        let fixture = try PlaybackFixture()
        let backend = PlaybackTestBackend()
        let controller = PlaybackController(output: DeviceOutput(backend: backend), devices: { backend.devices }, automaticPolling: false)
        try await controller.open(url: fixture.wav(rate: 48_000))
        XCTAssertThrowsError(try controller.set(mode: .cue, parameters: .init(strength: .nan, cutoffHz: 1_500), gainDB: 0))
        XCTAssertEqual(controller.mode, .mono); XCTAssertEqual(controller.gainDB, -18)
        XCTAssertNotNil(controller.lastError)
        for seconds in [Double.nan, .infinity, -1, 100] {
            do { try await controller.seek(seconds: seconds); XCTFail("Invalid seek") } catch {}
        }
        XCTAssertEqual(backend.starts, 0)
        controller.selectOutput(uid: "test", ear: .left); await controller.waitUntilSettled()
        try await controller.seek(seconds: 0.1)
        XCTAssertEqual(controller.positionSeconds, 0.1)
        XCTAssertEqual(backend.starts, 0)
        try await controller.playConfirmationTone()
        XCTAssertEqual(controller.phase, .running)
        XCTAssertEqual(backend.starts, 1)
        controller.stop(); await controller.waitUntilSettled()
    }
}

extension PlaybackControllerTests {
    @MainActor func testEmptyFileNeverStartsDevice() async throws {
        let fixture = try PlaybackFixture()
        let backend = PlaybackTestBackend()
        let controller = PlaybackController(output: DeviceOutput(backend: backend), devices: { backend.devices }, automaticPolling: false)
        try await controller.open(url: fixture.wav(rate: 48_000, frames: 0))
        controller.selectOutput(uid: "test", ear: .left); await controller.waitUntilSettled()
        try await controller.play()
        XCTAssertEqual(backend.starts, 0)
        XCTAssertEqual(controller.phase, .stopped)
        controller.stop(); await controller.waitUntilSettled()
    }
    @MainActor func testPausedEOFIsRetainedUntilExplicitResume() async throws {
        let fixture = try PlaybackFixture()
        let backend = PlaybackTestBackend()
        let clock = PlaybackControllerClock()
        let controller = PlaybackController(output: DeviceOutput(backend: backend), devices: { backend.devices }, now: { clock.now }, automaticPolling: false)
        try await controller.open(url: fixture.wav(rate: 48_000, frames: 17))
        controller.selectOutput(uid: "test", ear: .left); await controller.waitUntilSettled()
        try await controller.play()
        _ = backend.render(257, ear: .left)
        controller.pause(); await controller.waitUntilSettled()
        let retained = backend.owner
        clock.now = 10; controller.pollForTesting(); await controller.waitUntilSettled()
        XCTAssertEqual(controller.phase, .paused)
        XCTAssertTrue(retained === backend.owner)
        try await controller.play()
        clock.now = 10.021; controller.pollForTesting(); await controller.waitUntilSettled()
        XCTAssertEqual(controller.phase, .stopped)
    }
    @MainActor func testToneWithoutFilePublishesMetadataAndResumesExplicitly() async throws {
        let backend = PlaybackTestBackend()
        let controller = PlaybackController(output: DeviceOutput(backend: backend), devices: { backend.devices }, automaticPolling: false)
        controller.selectOutput(uid: "test", ear: .right); await controller.waitUntilSettled()
        try await controller.playConfirmationTone()
        XCTAssertEqual(controller.channelCount, 2)
        XCTAssertEqual(controller.durationSeconds, 0.5)
        controller.pause(); await controller.waitUntilSettled()
        try await controller.play()
        XCTAssertEqual(controller.phase, .running)
        controller.stop(); await controller.waitUntilSettled()
        XCTAssertEqual(controller.channelCount, 0)
        XCTAssertEqual(controller.durationSeconds, 0)
    }
    @MainActor func testCleanupTimeoutRetainsOneSessionAndBlocksRestartUntilAcknowledged() async throws {
        let fixture = try PlaybackFixture()
        let backend = PlaybackTestBackend()
        let controller = PlaybackController(output: DeviceOutput(backend: backend), devices: { backend.devices }, automaticPolling: false)
        try await controller.open(url: fixture.wav(rate: 48_000))
        controller.selectOutput(uid: "test", ear: .left); await controller.waitUntilSettled()
        try await controller.play()
        backend.renderCompletionConfirmed = false
        controller.stop(); await controller.waitUntilSettled()
        XCTAssertEqual(controller.phase, .error)
        XCTAssertNotNil(controller.lastError)
        do { try await controller.play(); XCTFail("Unacknowledged output must block start") } catch {}
        XCTAssertEqual(backend.starts, 1)
        backend.renderCompletionConfirmed = true
        controller.stop(); await controller.waitUntilSettled()
        XCTAssertEqual(controller.phase, .stopped)
        try await controller.play()
        XCTAssertEqual(backend.starts, 2)
        controller.stop(); await controller.waitUntilSettled()
    }
    @MainActor func testThreeUnderrunsAcrossWindowBoundaryStop() async throws {
        let fixture = try PlaybackFixture()
        let backend = PlaybackTestBackend()
        let clock = PlaybackControllerClock()
        let controller = PlaybackController(output: DeviceOutput(backend: backend), devices: { backend.devices }, now: { clock.now }, automaticPolling: false)
        try await controller.open(url: fixture.wav(rate: 48_000, frames: 96_000))
        controller.selectOutput(uid: "test", ear: .left); await controller.waitUntilSettled()
        try await controller.play()
        for time in [0.9, 1.1, 1.2] {
            clock.now = time
            let part = backend.render(5_000, ear: .left)
            XCTAssertGreaterThan(part.consumed, 0)
            controller.pollForTesting()
            try await Task.sleep(for: .milliseconds(12))
        }
        await controller.waitUntilSettled()
        XCTAssertEqual(controller.phase, .stopped)
        XCTAssertNotNil(controller.lastError)
        controller.stop(); await controller.waitUntilSettled()
    }
}

extension PlaybackControllerTests {
    @MainActor func testSeekDuringPreparationThenStopCannotStartOldAudio() async throws {
        let fixture = try PlaybackFixture()
        let backend = PlaybackTestBackend()
        let controller = PlaybackController(output: DeviceOutput(backend: backend), devices: { backend.devices }, automaticPolling: false)
        try await controller.open(url: fixture.wav(rate: 44_100))
        controller.selectOutput(uid: "test", ear: .left); await controller.waitUntilSettled()
        try await controller.play()
        let entered = expectation(description: "seek configure blocked")
        var release: CheckedContinuation<Void, Never>?
        backend.configureHook = { await withCheckedContinuation { release = $0; entered.fulfill() } }
        let seek = Task { try await controller.seek(seconds: 0.1) }
        await fulfillment(of: [entered], timeout: 3)
        controller.stop(); release?.resume()
        _ = try? await seek.value
        await controller.waitUntilSettled()
        XCTAssertEqual(controller.phase, .stopped)
        XCTAssertEqual(controller.positionSeconds, 0)
        XCTAssertEqual(backend.starts, 1)
    }
    @MainActor func testMonoModesAndToneSeekAreRejectedWithoutChangingMusicSource() async throws {
        let fixture = try PlaybackFixture()
        let backend = PlaybackTestBackend()
        let controller = PlaybackController(output: DeviceOutput(backend: backend), devices: { backend.devices }, automaticPolling: false)
        try await controller.open(url: fixture.wav(rate: 48_000, channels: 1))
        XCTAssertEqual(controller.channelCount, 1)
        for mode in [ListeningMode.leftOnly, .rightOnly] {
            XCTAssertThrowsError(try controller.set(mode: mode, parameters: .init(strength: 0.35, cutoffHz: 1500), gainDB: -18))
        }
        controller.selectOutput(uid: "test", ear: .left); await controller.waitUntilSettled()
        try await controller.playConfirmationTone()
        let tone = backend.owner
        do { try await controller.seek(seconds: 0.1); XCTFail("Tone must not seek selected music") } catch {}
        XCTAssertTrue(tone === backend.owner)
        XCTAssertEqual(backend.starts, 1)
        controller.stop(); await controller.waitUntilSettled()
        XCTAssertEqual(controller.channelCount, 1)
        try await controller.play()
        XCTAssertEqual(backend.starts, 2)
        controller.stop(); await controller.waitUntilSettled()
    }
    @MainActor func testControllerDeinitStopsOutput() async throws {
        let fixture = try PlaybackFixture()
        let backend = PlaybackTestBackend()
        var controller: PlaybackController? = PlaybackController(output: DeviceOutput(backend: backend), devices: { backend.devices }, automaticPolling: false)
        try await controller!.open(url: fixture.wav(rate: 48_000))
        controller!.selectOutput(uid: "test", ear: .left); await controller!.waitUntilSettled()
        try await controller!.play()
        weak let weakController = controller
        let owner = try XCTUnwrap(backend.owner)
        controller = nil
        XCTAssertNil(weakController)
        XCTAssertTrue(owner.stats.silenced)
        XCTAssertNil(backend.owner)
    }
}

extension PlaybackControllerTests {
    @MainActor func testRunningSeekReplacesOldPCMAndPausedSeekRemainsSilent() async throws {
        let fixture = try PlaybackFixture()
        for sourceRate in [44_100.0, 48_000.0] {
            let url = try fixture.wav(rate: sourceRate)
            for outputRate in [44_100.0, 48_000.0] {
                let backend = PlaybackTestBackend()
                backend.devices = [.init(uid: "test", name: "Test", sampleRate: outputRate, channels: 2, deviceID: 42)]
                let controller = PlaybackController(output: DeviceOutput(backend: backend), devices: { backend.devices }, automaticPolling: false)
                try await controller.open(url: url)
                try controller.set(mode: .cue, parameters: .init(strength: 0.35, cutoffHz: 1500), gainDB: -18)
                controller.selectOutput(uid: "test", ear: .left); await controller.waitUntilSettled()
                try await controller.play()
                let old = try XCTUnwrap(backend.owner)
                _ = backend.render(17, ear: .left)
                try await controller.seek(seconds: 0.1)
                XCTAssertEqual(controller.phase, .running)
                XCTAssertTrue(old.stats.silenced)
                XCTAssertFalse(old === backend.owner)
                let reference = try fixture.pipeline(url, outputRate: outputRate)
                try reference.seek(sourceFrame: Int64(0.1 * sourceRate))
                let expected = try fixture.collect(reference)
                var actual: [Float] = []
                for _ in 0..<1_000 {
                    if actual.count == expected.count { break }
                    let part = backend.render(min(127, expected.count - actual.count), ear: .left)
                    XCTAssertTrue(part.other.allSatisfy { $0 == 0 })
                    actual.append(contentsOf: part.pcm.prefix(part.consumed))
                    try await Task.sleep(for: .milliseconds(2))
                }
                XCTAssertEqual(actual.map(\.bitPattern), expected.map(\.bitPattern))
                controller.pause(); await controller.waitUntilSettled()
                let starts = backend.starts
                try await controller.seek(seconds: 0.05)
                XCTAssertEqual(controller.phase, .stopped)
                XCTAssertEqual(controller.positionSeconds, 0.05)
                XCTAssertNil(backend.owner)
                XCTAssertEqual(backend.starts, starts)
                controller.stop(); await controller.waitUntilSettled()
            }
        }
    }
    @MainActor func testOneThousandSoftwareStartRenderStopCycles() async throws {
        let fixture = try PlaybackFixture()
        let backend = PlaybackTestBackend()
        let controller = PlaybackController(output: DeviceOutput(backend: backend), devices: { backend.devices }, automaticPolling: false)
        try await controller.open(url: fixture.wav(rate: 48_000, frames: 17))
        controller.selectOutput(uid: "test", ear: .left); await controller.waitUntilSettled()
        for cycle in 0..<1_000 {
            try await controller.play()
            XCTAssertEqual(backend.render(257, ear: .left).consumed, 257, "cycle \(cycle)")
            controller.stop(); await controller.waitUntilSettled()
            XCTAssertEqual(controller.phase, .stopped, "cycle \(cycle)")
            XCTAssertNil(controller.diagnostics.sessionID, "cycle \(cycle)")
            XCTAssertNil(backend.owner, "cycle \(cycle)")
        }
        XCTAssertEqual(backend.starts, 1_000)
    }
}

extension PlaybackControllerTests {
    @MainActor func testPauseBeforeOutputPreparationCanResumeSameSession() async throws {
        let fixture = try PlaybackFixture()
        let backend = PlaybackTestBackend()
        let controller = PlaybackController(output: DeviceOutput(backend: backend), devices: { backend.devices }, automaticPolling: false)
        try await controller.open(url: fixture.wav(rate: 48_000, frames: 96_000))
        controller.selectOutput(uid: "test", ear: .left); await controller.waitUntilSettled()
        let start = Task { try await controller.play() }
        for _ in 0..<10_000 {
            if controller.phase == .preparing { break }
            await Task.yield()
        }
        XCTAssertEqual(controller.phase, .preparing)
        let sessionID = controller.diagnostics.sessionID
        controller.pause()
        _ = try? await start.value
        await controller.waitUntilSettled()
        XCTAssertEqual(controller.phase, .paused)
        XCTAssertEqual(backend.starts, 0)
        try await controller.play()
        XCTAssertEqual(controller.phase, .running)
        XCTAssertEqual(controller.diagnostics.sessionID, sessionID)
        XCTAssertEqual(backend.starts, 1)
        controller.stop(); await controller.waitUntilSettled()
    }
}

extension PlaybackControllerTests {
    @MainActor func testEarlyPausedToneKeepsItsMetadata() async throws {
        let backend = PlaybackTestBackend()
        let controller = PlaybackController(output: DeviceOutput(backend: backend), devices: { backend.devices }, automaticPolling: false)
        controller.selectOutput(uid: "test", ear: .left); await controller.waitUntilSettled()
        let start = Task { try await controller.playConfirmationTone() }
        for _ in 0..<10_000 {
            if controller.phase == .preparing { break }
            await Task.yield()
        }
        controller.pause(); _ = try? await start.value
        await controller.waitUntilSettled()
        XCTAssertEqual(controller.phase, .paused)
        XCTAssertEqual(controller.channelCount, 2)
        XCTAssertEqual(controller.durationSeconds, 0.5)
        XCTAssertFalse(controller.canSeek)
        try await controller.play()
        XCTAssertEqual(controller.durationSeconds, 0.5)
        controller.stop(); await controller.waitUntilSettled()
    }
}

extension PlaybackControllerTests {
    @MainActor func testBlockedPreparationStopsWithinDeadlineAndStoresFutureMute() async throws {
        let fixture = try PlaybackFixture()
        let backend = PlaybackTestBackend()
        let gate = PlaybackPreparationGate()
        let controller = PlaybackController(output: DeviceOutput(backend: backend), devices: { backend.devices }, automaticPolling: false,
                                            pipelineFactory: { url, rate in
            gate.enterIfArmed()
            return try AudioFilePipeline(url: url, outputRate: rate)
        })
        try await controller.open(url: fixture.wav(rate: 48_000))
        controller.selectOutput(uid: "test", ear: .left); await controller.waitUntilSettled()
        gate.arm()
        let start = Task { try await controller.play() }
        let arrived = await Task.detached { gate.barrier.waitForArrival() }.value
        XCTAssertTrue(arrived)
        controller.stop()
        do { try controller.set(mode: .mono, parameters: .init(strength: 0.35, cutoffHz: 1500), gainDB: nil) }
        catch { XCTFail("Stopped producer must not reject future mute") }
        XCTAssertNil(controller.gainDB)
        try await Task.sleep(for: .milliseconds(2_200))
        XCTAssertEqual(controller.phase, .error)
        XCTAssertNotNil(controller.lastError)
        XCTAssertEqual(backend.starts, 0)
        gate.barrier.resume()
        _ = try? await start.value
        controller.stop(); await controller.waitUntilSettled()
        try await controller.play()
        XCTAssertTrue(backend.render(2_048, ear: .left).pcm.allSatisfy { $0 == 0 })
        controller.stop(); await controller.waitUntilSettled()
    }
}

extension PlaybackControllerTests {
    @MainActor func testUnsupportedInputKeepsSanitizedReasonAfterCleanup() async throws {
        let fixture = try PlaybackFixture()
        let backend = PlaybackTestBackend()
        let controller = PlaybackController(output: DeviceOutput(backend: backend), devices: { backend.devices }, automaticPolling: false)
        let url = try fixture.wav(rate: 48_000, channels: 3)
        do { try await controller.open(url: url); XCTFail("Unsupported channels") } catch {}
        XCTAssertEqual(controller.lastError, "モノラルまたはステレオの音源に対応しています。")
        XCTAssertFalse(controller.lastError?.contains(url.path) ?? true)
        XCTAssertEqual(controller.phase, .stopped)
        XCTAssertNil(controller.diagnostics.sessionID)
        XCTAssertEqual(backend.starts, 0)
    }
}

extension PlaybackControllerTests {
    @MainActor func testFinalRoutingMatrixForFileAndToneEveryModeEarRateAndMute() async throws {
        let fixture = try PlaybackFixture()
        let url = try fixture.wav(rate: 48_000)
        let ceiling = Float(pow(10.0, -3.0 / 20))
        for rate in [44_100.0, 48_000.0] {
            for ear in [HearingEar.left, .right] {
                let backend = PlaybackTestBackend()
                backend.devices = [.init(uid: "test", name: "Test", sampleRate: rate, channels: 2, deviceID: 42)]
                let controller = PlaybackController(output: DeviceOutput(backend: backend), devices: { backend.devices }, automaticPolling: false)
                try await controller.open(url: url)
                controller.selectOutput(uid: "test", ear: ear); await controller.waitUntilSettled()
                for tone in [false, true] {
                    for mode in [ListeningMode.mono, .cue, .leftOnly, .rightOnly] {
                        for gain: Float? in [0, nil] {
                            try controller.set(mode: mode, parameters: .init(strength: 0.35, cutoffHz: 1500), gainDB: gain)
                            if tone { try await controller.playConfirmationTone() }
                            else { try await controller.play() }
                            let part = backend.render(2_048, ear: ear)
                            XCTAssertEqual(part.consumed, 2_048)
                            XCTAssertTrue(part.other.allSatisfy { $0 == 0 })
                            XCTAssertTrue(part.pcm.allSatisfy { $0.isFinite && abs($0) <= ceiling })
                            if gain == nil { XCTAssertTrue(part.pcm.allSatisfy { $0 == 0 }) }
                            else { XCTAssertTrue(part.pcm.contains { $0 != 0 }) }
                            controller.stop(); await controller.waitUntilSettled()
                        }
                    }
                }
            }
        }
    }
}

extension PlaybackControllerTests {
    @MainActor func testStopSupersedesResumeWhilePreparationIsBlocked() async throws {
        let fixture = try PlaybackFixture()
        let backend = PlaybackTestBackend()
        let gate = PlaybackPreparationGate()
        let controller = PlaybackController(output: DeviceOutput(backend: backend), devices: { backend.devices }, automaticPolling: false,
                                            pipelineFactory: { url, rate in
            gate.enterIfArmed()
            return try AudioFilePipeline(url: url, outputRate: rate)
        })
        try await controller.open(url: fixture.wav(rate: 48_000))
        controller.selectOutput(uid: "test", ear: .left); await controller.waitUntilSettled()
        gate.arm()
        let start = Task { try? await controller.play() }
        let arrived = await Task.detached { gate.barrier.waitForArrival() }.value
        XCTAssertTrue(arrived)
        controller.pause()
        let resume = Task { try? await controller.play() }
        let deadline = ContinuousClock.now + .seconds(1)
        while controller.phase != .preparing, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(controller.phase, .preparing)
        controller.stop()
        try await Task.sleep(for: .milliseconds(2_200))
        XCTAssertEqual(controller.phase, .error, "Stop must reach its cleanup deadline while resume is pending")
        XCTAssertNotNil(controller.lastError)
        XCTAssertEqual(backend.starts, 0)
        gate.barrier.resume()
        await start.value; await resume.value
        controller.stop(); await controller.waitUntilSettled()
        XCTAssertEqual(controller.phase, .stopped)
        try await controller.play()
        XCTAssertEqual(backend.starts, 1)
        controller.stop(); await controller.waitUntilSettled()
    }

    @MainActor func testOpenMonoAfterSingleChannelModePreservesOtherSettings() async throws {
        let fixture = try PlaybackFixture()
        let backend = PlaybackTestBackend()
        let controller = PlaybackController(output: DeviceOutput(backend: backend), devices: { backend.devices }, automaticPolling: false)
        for mode in [ListeningMode.leftOnly, .rightOnly] {
            try await controller.open(url: fixture.wav(rate: 48_000, channels: 2))
            try controller.set(mode: mode, parameters: .init(strength: 0.5, cutoffHz: 2_000), gainDB: nil)
            do { try await controller.open(url: fixture.wav(rate: 48_000, channels: 1)) }
            catch { XCTFail("Opening supported mono must not depend on the previous mode") }
            XCTAssertEqual(controller.channelCount, 1)
            XCTAssertEqual(controller.mode, .mono)
            XCTAssertEqual(controller.parameters.strength, 0.5)
            XCTAssertEqual(controller.parameters.cutoffHz, 2_000)
            XCTAssertNil(controller.gainDB)
            XCTAssertTrue(controller.canSeek)
            XCTAssertEqual(backend.starts, 0)
            XCTAssertThrowsError(try controller.set(mode: mode, parameters: controller.parameters, gainDB: nil))
        }
        controller.stop(); await controller.waitUntilSettled()
    }

    @MainActor func testOpeningFileDuringToneRestoresSeekingWithoutPlayback() async throws {
        let fixture = try PlaybackFixture()
        let backend = PlaybackTestBackend()
        let controller = PlaybackController(output: DeviceOutput(backend: backend), devices: { backend.devices }, automaticPolling: false)
        controller.selectOutput(uid: "test", ear: .left); await controller.waitUntilSettled()
        try await controller.playConfirmationTone()
        XCTAssertFalse(controller.canSeek)
        try await controller.open(url: fixture.wav(rate: 48_000))
        XCTAssertEqual(controller.phase, .stopped)
        XCTAssertTrue(controller.canSeek)
        do { try await controller.seek(seconds: 0.1) }
        catch { XCTFail("Newly opened file must be seekable after a tone") }
        XCTAssertEqual(controller.positionSeconds, 0.1)
        XCTAssertEqual(backend.starts, 1)
        controller.stop(); await controller.waitUntilSettled()
    }
}
