import XCTest
import AVFAudio
import AudioToolbox
@testable import MonoOtoAudio

final class DeviceOutputTests: XCTestCase {
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
        XCTAssertThrowsError(try output.prepare(uid: "missing", sampleRate: 48000))
        XCTAssertFalse(output.isRunning)
        XCTAssertNil(output.selectedUID)
        XCTAssertEqual(backend.configureCount, 0)
        XCTAssertEqual(backend.startCount, 0)
    }

    @MainActor func testFailedPreparationClearsPreviousCallbackDiagnostics() {
        let backend = FakeOutputBackend()
        backend.callbackCount = 12
        let output = DeviceOutput(backend: backend)

        XCTAssertThrowsError(try output.prepare(uid: "missing", sampleRate: 48_000))

        XCTAssertEqual(output.callbackCount, 0)
    }

    @MainActor func testPrepareDoesNotStartAndRequiresFreshPreparationAfterStop() async throws {
        let backend = FakeOutputBackend()
        let output = DeviceOutput(backend: backend)
        try output.prepare(uid: "headphones", sampleRate: 48000)
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

    @MainActor func testDeinitSchedulesBackendDisposal() async {
        let backend = FakeOutputBackend()
        var output: DeviceOutput? = DeviceOutput(backend: backend)
        weak let releasedOutput = output

        output = nil
        await Task.yield()

        XCTAssertNil(releasedOutput)
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
            XCTAssertThrowsError(try output.prepare(uid: "headphones", sampleRate: 48000))
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
        try output.prepare(uid: "headphones", sampleRate: 48000)
        backend.devices = []
        XCTAssertThrowsError(try output.startSilence())
        XCTAssertFalse(output.isRunning)
        XCTAssertEqual(backend.startCount, 0)
    }

    @MainActor func testLossDefaultFormatAndSleepEventsInvalidatePreparation() async throws {
        for event in [DeviceOutputEvent.deviceChanged, .defaultChanged, .configurationChanged, .sleep, .renderFault] {
            let backend = FakeOutputBackend()
            let output = DeviceOutput(backend: backend)
            try output.prepare(uid: "headphones", sampleRate: 48000)
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
                try output.prepare(uid: "headphones", sampleRate: 48000)
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
        try output.prepare(uid: "headphones", sampleRate: 48000)
        let oldHandler = try XCTUnwrap(backend.handler)
        output.stop()
        try output.prepare(uid: "headphones", sampleRate: 48000)
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
            try output.prepare(uid: "headphones", sampleRate: 48000)
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
    var stopCount = 0
    var disposeCount = 0
    func availableDevices() throws -> [OutputDevice] { devices }
    func configure(device: OutputDevice, sampleRate: Double, onEvent: @escaping @MainActor @Sendable (DeviceOutputEvent) -> Void) throws {
        configureCount += 1
        handler = onEvent
        if failConfiguration { throw DeviceOutputError.unavailable }
    }
    func snapshot() throws -> DeviceOutputSnapshot { report }
    func start() throws { startCount += 1; if changeOnStart { report.deviceID = 99 } }
    func stop() { stopCount += 1 }
    func dispose() { disposeCount += 1; handler = nil }
    func resetDiagnostics() { callbackCount = 0 }
}
