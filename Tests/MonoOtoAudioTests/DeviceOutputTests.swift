import XCTest
import AVFAudio
import AudioToolbox
@testable import MonoOtoAudio

final class DeviceOutputTests: XCTestCase {
    @MainActor private func expectPreparationFailure(
        _ output: DeviceOutput, uid: String = "headphones",
        expected: DeviceOutputError = .unavailable,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            try await output.prepare(uid: uid, sampleRate: 48000)
            XCTFail("Preparation unexpectedly succeeded", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? DeviceOutputError, expected, file: file, line: line)
        }
    }

    @MainActor func testConfigurationWaitConsumesOnlyFirstNotification() async throws {
        let wait = DeviceConfigurationWait()
        XCTAssertTrue(wait.receiveExpectedChange())
        try await wait.wait()
        XCTAssertFalse(wait.receiveExpectedChange())
    }

    @MainActor func testConfigurationWaitSuspendsUntilNotification() async throws {
        let wait = DeviceConfigurationWait()
        let entered = expectation(description: "waiting")
        var completed = false
        let task = Task { @MainActor in
            entered.fulfill()
            try await wait.wait()
            completed = true
        }
        await fulfillment(of: [entered], timeout: 1)
        XCTAssertFalse(completed)
        XCTAssertTrue(wait.isWaiting, "Must exercise the suspended continuation, not the cached result")
        XCTAssertTrue(wait.receiveExpectedChange())
        try await task.value
        XCTAssertTrue(completed)
        XCTAssertFalse(wait.receiveExpectedChange())
    }

    @MainActor func testConfigurationWaitTimeoutRejectsLateNotification() async {
        let wait = DeviceConfigurationWait()
        do {
            try await wait.wait(timeout: .milliseconds(1))
            XCTFail("Missing notification must time out")
        } catch {
            guard case DeviceOutputError.configurationTimeout = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertFalse(wait.receiveExpectedChange())
    }

    @MainActor func testConfigurationWaitCancellationWinsQueuedTimeout() async {
        let wait = DeviceConfigurationWait()
        let entered = expectation(description: "waiting")
        let task = Task { @MainActor in
            entered.fulfill()
            try await wait.wait()
        }
        await fulfillment(of: [entered], timeout: 1)
        XCTAssertTrue(wait.isWaiting)
        // Resume with a timeout, then cancel before the waiter can run on this actor.
        wait.timeOut()
        task.cancel()
        do { try await task.value; XCTFail("Cancelled wait succeeded") }
        catch { XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)") }
        XCTAssertFalse(wait.receiveExpectedChange())
    }

    @MainActor func testConfigurationWaitDisposeCancellationBeforeAndDuringWait() async {
        for beforeWait in [false, true] {
            let wait = DeviceConfigurationWait()
            if beforeWait { wait.cancel() }
            let entered = expectation(description: "waiting")
            let task = Task { @MainActor in
                entered.fulfill()
                try await wait.wait()
            }
            await fulfillment(of: [entered], timeout: 1)
            wait.cancel()
            wait.cancel()
            do {
                try await task.value
                XCTFail("Disposed preparation must not complete")
            } catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertFalse(wait.receiveExpectedChange())
        }
    }

    @MainActor func testConfigurationWaitTaskCancellationRejectsNotification() async {
        let wait = DeviceConfigurationWait()
        let entered = expectation(description: "waiting")
        let task = Task { @MainActor in
            entered.fulfill()
            try await wait.wait()
        }
        await fulfillment(of: [entered], timeout: 1)
        task.cancel()
        do {
            try await task.value
            XCTFail("Cancelled preparation must not complete")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(wait.receiveExpectedChange())
    }

    @MainActor func testPendingPreparationHardwareEventsCannotRestorePreparation() async throws {
        for event in [DeviceOutputEvent.deviceChanged, .defaultChanged, .configurationChanged, .sleep, .renderFault] {
            let backend = FakeOutputBackend()
            let output = DeviceOutput(backend: backend)
            let entered = expectation(description: "configuration pending")
            var pending: CheckedContinuation<Void, Never>?
            backend.configureHook = {
                await withCheckedContinuation { continuation in
                    pending = continuation
                    entered.fulfill()
                }
            }
            let task = Task { @MainActor in try await output.prepare(uid: "headphones", sampleRate: 48000) }
            await fulfillment(of: [entered], timeout: 1)
            backend.handler?(event)
            let eventError = output.lastError
            pending?.resume()
            do { try await task.value; XCTFail("Event must invalidate preparation") }
            catch { XCTAssertEqual(error as? DeviceOutputError, .stale) }
            XCTAssertFalse(output.isRunning)
            XCTAssertNil(output.verifiedDeviceID)
            XCTAssertNotNil(eventError)
            XCTAssertEqual(output.lastError, eventError)
        }
    }

    @MainActor func testReadbackMismatchAfterSuspendedPreparationFailsClosed() async {
        let backend = FakeOutputBackend()
        let output = DeviceOutput(backend: backend)
        let entered = expectation(description: "configuration pending")
        var pending: CheckedContinuation<Void, Never>?
        backend.configureHook = {
            await withCheckedContinuation { continuation in
                pending = continuation
                entered.fulfill()
            }
        }
        let task = Task { @MainActor in try await output.prepare(uid: "headphones", sampleRate: 48000) }
        await fulfillment(of: [entered], timeout: 1)
        backend.report.deviceID = 99
        pending?.resume()
        do { try await task.value; XCTFail("Changed route must be rejected") }
        catch { XCTAssertEqual(error as? DeviceOutputError, .changed) }
        XCTAssertNil(output.verifiedDeviceID)
        XCTAssertFalse(output.isRunning)
        XCTAssertNotNil(output.lastError)
    }

    @MainActor func testAlreadyCancelledPreparationStopsPreviousOutput() async throws {
        for running in [false, true] {
            let backend = FakeOutputBackend()
            let output = DeviceOutput(backend: backend)
            try await output.prepare(uid: "headphones", sampleRate: 48000)
            if running { try output.startSilence() }
            let disposals = backend.disposeCount
            // The main actor cannot begin this task until we yield below.
            let task = Task { @MainActor in
                try await output.prepare(uid: "headphones", sampleRate: 48000)
            }
            task.cancel()
            do { try await task.value; XCTFail("Cancelled preparation succeeded") }
            catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertFalse(output.isRunning)
            XCTAssertNil(output.verifiedDeviceID)
            XCTAssertNil(output.selectedUID)
            XCTAssertGreaterThan(backend.disposeCount, disposals)
            XCTAssertEqual(backend.configureCount, 1)
        }
    }

    @MainActor func testPreparationTaskCancellationFailsClosed() async {
        let backend = FakeOutputBackend()
        let output = DeviceOutput(backend: backend)
        let entered = expectation(description: "configuration pending")
        var pending: CheckedContinuation<Void, Never>?
        backend.configureHook = {
            await withCheckedContinuation { continuation in
                pending = continuation
                entered.fulfill()
            }
        }
        let task = Task { @MainActor in try await output.prepare(uid: "headphones", sampleRate: 48000) }
        await fulfillment(of: [entered], timeout: 1)
        task.cancel()
        pending?.resume()
        do { try await task.value; XCTFail("Cancelled preparation must be rejected") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertNil(output.verifiedDeviceID)
        XCTAssertFalse(output.isRunning)
    }

    @MainActor func testOldPreparationCompletionCannotStopNewGeneration() async throws {
        for failOld in [false, true] {
            let backend = FakeOutputBackend()
            let output = DeviceOutput(backend: backend)
            backend.configureHook = {
                backend.configureHook = nil
                output.stop()
                try await output.prepare(uid: "headphones", sampleRate: 48000)
                try output.startSilence()
                if failOld { throw DeviceOutputError.unavailable }
            }
            await expectPreparationFailure(output, expected: failOld ? .unavailable : .stale)
            XCTAssertTrue(output.isRunning, "old failure=\(failOld)")
            XCTAssertEqual(output.verifiedDeviceID, 7)
            XCTAssertNil(output.lastError)
            output.stop()
        }
    }

    @MainActor func testSuspendedOldPreparationSuccessAndFailureCannotStopNewGeneration() async throws {
        for failOld in [false, true] {
            let backend = FakeOutputBackend()
            let output = DeviceOutput(backend: backend)
            let entered = expectation(description: "old configuration pending")
            var pending: CheckedContinuation<Void, Error>?
            backend.configureHook = {
                try await withCheckedThrowingContinuation { continuation in
                    pending = continuation
                    entered.fulfill()
                }
            }
            let old = Task { @MainActor in try await output.prepare(uid: "headphones", sampleRate: 48000) }
            await fulfillment(of: [entered], timeout: 1)
            output.stop()
            backend.configureHook = nil
            try await output.prepare(uid: "headphones", sampleRate: 48000)
            try output.startSilence()
            if failOld { pending?.resume(throwing: DeviceOutputError.unavailable) }
            else { pending?.resume() }
            do { try await old.value; XCTFail("Old preparation must be rejected") }
            catch { XCTAssertEqual(error as? DeviceOutputError, failOld ? .unavailable : .stale) }
            XCTAssertTrue(output.isRunning)
            XCTAssertEqual(output.verifiedDeviceID, 7)
            XCTAssertNil(output.lastError)
            output.stop()
        }
    }

    func testDeviceDiscoverySkipsUnreadableDeviceAndKeepsValidDevice() {
        let devices = discoverOutputDevices(ids: [1, 2, 3]) { id in
            switch id {
            case 1:
                throw DeviceOutputError.unavailable
            case 2:
                return OutputDevice(
                    uid: "headphones", name: "Headphones", sampleRate: 48_000,
                    channels: 2, deviceID: id
                )
            default:
                return nil
            }
        }

        XCTAssertEqual(devices.map(\.uid), ["headphones"])
    }

    func testStageASupportRequiresStereoAndSupportedFiniteRate() {
        XCTAssertTrue(OutputDevice(
            uid: "supported", name: "Supported", sampleRate: 44_100,
            channels: 2, deviceID: 1
        ).isSupportedForStageA)
        XCTAssertFalse(OutputDevice(
            uid: "surround", name: "Surround", sampleRate: 48_000,
            channels: 8, deviceID: 2
        ).isSupportedForStageA)
        XCTAssertFalse(OutputDevice(
            uid: "high-rate", name: "High rate", sampleRate: 96_000,
            channels: 2, deviceID: 3
        ).isSupportedForStageA)
        XCTAssertFalse(OutputDevice(
            uid: "invalid-rate", name: "Invalid rate", sampleRate: .nan,
            channels: 2, deviceID: 4
        ).isSupportedForStageA)
    }

    func testRenderWritesOnlyZerosAndCountsCallbacks() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32))
        buffer.frameLength = 32
        let channels = try XCTUnwrap(buffer.floatChannelData)
        for channel in 0..<2 { for frame in 0..<32 { channels[channel][frame] = 0.75 } }
        let state = SilenceRenderState()
        XCTAssertEqual(state.render(frames: 32, buffers: buffer.mutableAudioBufferList), noErr)
        XCTAssertEqual(state.callbackCount, 1)
        XCTAssertFalse(state.hasFault)
        for channel in 0..<2 { for frame in 0..<32 { XCTAssertEqual(channels[channel][frame], 0) } }
    }

    func testInvalidRenderLatchesFaultAndStillZerosValidChannel() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32))
        buffer.frameLength = 32
        let channels = try XCTUnwrap(buffer.floatChannelData)
        for frame in 0..<32 { channels[1][frame] = 0.5 }
        let rawList = buffer.mutableAudioBufferList
        let list = UnsafeMutableAudioBufferListPointer(rawList)
        list[0].mDataByteSize = 0
        let state = SilenceRenderState()
        XCTAssertNotEqual(state.render(frames: 32, buffers: rawList), noErr)
        XCTAssertTrue(state.hasFault)
        for frame in 0..<32 { XCTAssertEqual(channels[1][frame], 0) }
        list[0].mDataByteSize = 128
        XCTAssertEqual(state.render(frames: 32, buffers: rawList), noErr)
        XCTAssertTrue(state.hasFault)
        XCTAssertEqual(state.callbackCount, 2)
        XCTAssertNotEqual(state.render(frames: 16385, buffers: rawList), noErr)
    }

    @MainActor func testMissingUIDNeverStartsOrUsesDefault() async throws {
        let backend = FakeOutputBackend()
        let output = DeviceOutput(backend: backend)
        await expectPreparationFailure(output, uid: "missing")
        XCTAssertFalse(output.isRunning)
        XCTAssertNil(output.selectedUID)
        XCTAssertEqual(backend.configureCount, 0)
        XCTAssertEqual(backend.startCount, 0)
    }

    @MainActor func testFailedPreparationClearsPreviousCallbackDiagnostics() async {
        let backend = FakeOutputBackend()
        backend.callbackCount = 12
        let output = DeviceOutput(backend: backend)

        await expectPreparationFailure(output, uid: "missing")

        XCTAssertEqual(output.callbackCount, 0)
    }

    @MainActor func testPrepareDoesNotStartAndRequiresFreshPreparationAfterStop() async throws {
        let backend = FakeOutputBackend()
        let output = DeviceOutput(backend: backend)
        try await output.prepare(uid: "headphones", sampleRate: 48000)
        XCTAssertEqual(output.selectedUID, "headphones")
        XCTAssertFalse(output.isRunning)
        XCTAssertEqual(backend.startCount, 0)
        try output.startSilence()
        XCTAssertTrue(output.isRunning)
        output.stop()
        output.stop()
        XCTAssertFalse(output.isRunning)
        XCTAssertThrowsError(try output.startSilence())
        XCTAssertEqual(backend.startCount, 1)
        output.dispose()
        output.dispose()
    }

    @MainActor func testOwnerReleaseStopsBeforeReturningToMainActor() async throws {
        for event in [DeviceOutputEvent.deviceChanged, .defaultChanged, .configurationChanged] {
            let backend = FakeOutputBackend()
            var output: DeviceOutput? = DeviceOutput(backend: backend)
            try await output!.prepare(uid: "headphones", sampleRate: 48000)
            try output!.startSilence()
            let lateEvent = try XCTUnwrap(backend.handler)
            let disposals = backend.disposeCount
            weak let released = output
            output = nil
            // Do not yield: this is the window before a deferred cleanup task can run.
            XCTAssertNil(released)
            XCTAssertFalse(backend.isRunning, "Owner release must stop hardware synchronously on its actor")
            XCTAssertGreaterThan(backend.disposeCount, disposals)
            lateEvent(event)
            XCTAssertFalse(backend.isRunning, "An event after owner release must not leave hardware running")
            XCTAssertNil(backend.handler)
        }
    }

    @MainActor func testOffActorOwnerReleaseStillHandlesFaultBeforeDeferredDisposal() async throws {
        for event in [DeviceOutputEvent.deviceChanged, .defaultChanged, .configurationChanged, .sleep, .renderFault] {
            let backend = FakeOutputBackend()
            let owner = OutputReleaseBox(DeviceOutput(backend: backend))
            try await owner.output!.prepare(uid: "headphones", sampleRate: 48000)
            try owner.output!.startSilence()
            weak let released = owner.output
            let eventHandler = try XCTUnwrap(backend.handler)
            let disposals = backend.disposeCount
            releaseOffActorWhileHoldingMainActor(owner)
            XCTAssertNil(released)
            XCTAssertEqual(backend.disposeCount, disposals, "Deferred disposal cannot run yet")
            eventHandler(event)
            XCTAssertFalse(backend.isRunning, "Fault must stop even after weak owner becomes nil")
            XCTAssertGreaterThan(backend.disposeCount, disposals)
            XCTAssertNil(backend.handler)
        }
    }

    // Deliberately hold the actor only while an independent worker releases its last owner.
    // This fixes the race window without sleep or relying on task scheduling order.
    @MainActor private func releaseOffActorWhileHoldingMainActor(_ box: OutputReleaseBox) {
        let released = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            box.output = nil
            released.signal()
        }
        XCTAssertEqual(released.wait(timeout: .now() + 2), .success)
    }

    @MainActor func testDeinitDisposesBackendOnMainActor() {
        let backend = FakeOutputBackend()
        var output: DeviceOutput? = DeviceOutput(backend: backend)
        weak let releasedOutput = output

        output = nil

        XCTAssertNil(releasedOutput)
        XCTAssertEqual(backend.disposeCount, 1)
    }

    @MainActor func testOffActorOwnerReleaseEventuallyDisposesWithoutEvent() async {
        let backend = FakeOutputBackend()
        let owner = OutputReleaseBox(DeviceOutput(backend: backend))
        let disposed = expectation(description: "off-actor fallback disposed")
        backend.disposeHook = { disposed.fulfill() }
        weak let released = owner.output
        releaseOffActorWhileHoldingMainActor(owner)
        XCTAssertNil(released)
        XCTAssertEqual(backend.disposeCount, 0)
        await fulfillment(of: [disposed], timeout: 2)
        XCTAssertEqual(backend.disposeCount, 1)
    }

    @MainActor func testConfigurationFailureAndReadbackMismatchFailClosed() async throws {
        for failure in 0..<5 {
            let backend = FakeOutputBackend()
            switch failure {
            case 0: backend.failConfiguration = true
            case 1: backend.report.deviceID = 99
            case 2: backend.report.sampleRate = 44100
            case 3: backend.report.channels = 1
            default: backend.report.isStereo = false
            }
            let output = DeviceOutput(backend: backend)
            await expectPreparationFailure(output, expected: failure == 0 ? .unavailable :
                failure == 1 ? .changed : .unsupportedFormat)
            XCTAssertFalse(output.isRunning)
            XCTAssertNotNil(output.lastError)
            XCTAssertThrowsError(try output.startSilence())
            XCTAssertEqual(backend.startCount, 0)
            XCTAssertGreaterThan(backend.disposeCount, 0)
        }
    }

    @MainActor func testDeviceLostBeforeStartIsRejected() async throws {
        let backend = FakeOutputBackend()
        let output = DeviceOutput(backend: backend)
        try await output.prepare(uid: "headphones", sampleRate: 48000)
        backend.devices = []
        XCTAssertThrowsError(try output.startSilence())
        XCTAssertFalse(output.isRunning)
        XCTAssertEqual(backend.startCount, 0)
    }

    @MainActor func testLossDefaultFormatAndSleepEventsInvalidatePreparation() async throws {
        for event in [DeviceOutputEvent.deviceChanged, .defaultChanged, .configurationChanged, .sleep, .renderFault] {
            let backend = FakeOutputBackend()
            let output = DeviceOutput(backend: backend)
            try await output.prepare(uid: "headphones", sampleRate: 48000)
            try output.startSilence()
            backend.handler?(event)
            XCTAssertFalse(output.isRunning)
            XCTAssertNotNil(output.lastError)
            XCTAssertThrowsError(try output.startSilence())
        }
    }

    @MainActor func testNotificationsStopAndDisposeBackendWhilePreparedOrRunning() async throws {
        for running in [false, true] {
            for event in [DeviceOutputEvent.deviceChanged, .defaultChanged, .configurationChanged, .sleep, .renderFault] {
                let backend = FakeOutputBackend()
                let output = DeviceOutput(backend: backend)
                try await output.prepare(uid: "headphones", sampleRate: 48000)
                if running { try output.startSilence() }
                let notify = try XCTUnwrap(backend.handler)
                let stopsBeforeNotification = backend.stopCount
                let disposalsBeforeNotification = backend.disposeCount
                let context = "event=\(event), running=\(running)"

                notify(event)

                // Check before any cleanup or rejected restart can call stop on our behalf.
                XCTAssertGreaterThan(backend.stopCount, stopsBeforeNotification, context)
                XCTAssertGreaterThan(backend.disposeCount, disposalsBeforeNotification, context)
                XCTAssertFalse(output.isRunning, context)
                XCTAssertNil(output.selectedUID, context)
            }
        }
    }

    @MainActor func testLateObserverCannotStopNewGeneration() async throws {
        let backend = FakeOutputBackend()
        let output = DeviceOutput(backend: backend)
        try await output.prepare(uid: "headphones", sampleRate: 48000)
        let oldHandler = try XCTUnwrap(backend.handler)
        output.stop()
        try await output.prepare(uid: "headphones", sampleRate: 48000)
        try output.startSilence()
        oldHandler(.deviceChanged)
        XCTAssertTrue(output.isRunning)
        XCTAssertNil(output.lastError)
        output.dispose()
    }

    @MainActor func testReadbackChangedImmediatelyBeforeOrDuringStartStops() async throws {
        for duringStart in [false, true] {
            let backend = FakeOutputBackend()
            let output = DeviceOutput(backend: backend)
            try await output.prepare(uid: "headphones", sampleRate: 48000)
            if duringStart { backend.changeOnStart = true }
            else { backend.report.deviceID = 99 }
            XCTAssertThrowsError(try output.startSilence())
            XCTAssertFalse(output.isRunning)
            XCTAssertThrowsError(try output.startSilence())
        }
    }
}

@MainActor private final class FakeOutputBackend: DeviceOutputBackend {
    var callbackCount: UInt64 = 0
    var devices = [OutputDevice(uid: "headphones", name: "Headphones", sampleRate: 48000, channels: 2, deviceID: 7)]
    var report = DeviceOutputSnapshot(deviceID: 7, sampleRate: 48000, channels: 2, isStereo: true)
    var handler: (@MainActor @Sendable (DeviceOutputEvent) -> Void)?
    var failConfiguration = false
    var changeOnStart = false
    var configureCount = 0
    var startCount = 0
    var isRunning = false
    var stopCount = 0
    var disposeCount = 0
    var configureHook: (() async throws -> Void)?
    var disposeHook: (() -> Void)?
    func availableDevices() throws -> [OutputDevice] { devices }
    func configure(device: OutputDevice, sampleRate: Double, onEvent: @escaping @MainActor @Sendable (DeviceOutputEvent) -> Void) async throws {
        configureCount += 1
        handler = onEvent
        try await configureHook?()
        if failConfiguration { throw DeviceOutputError.unavailable }
    }
    func snapshot() throws -> DeviceOutputSnapshot { report }
    func start() throws { isRunning = true; startCount += 1; if changeOnStart { report.deviceID = 99 } }
    func stop() { isRunning = false; stopCount += 1 }
    func dispose() { isRunning = false; disposeCount += 1; handler = nil; disposeHook?() }
    func resetDiagnostics() { callbackCount = 0 }
}

// Exclusive handoff: initialized/read on main, then only the release worker mutates output.
private final class OutputReleaseBox: @unchecked Sendable {
    var output: DeviceOutput?
    init(_ output: DeviceOutput) { self.output = output }
}
