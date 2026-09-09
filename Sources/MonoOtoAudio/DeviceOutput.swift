import AppKit
import AVFAudio
import AudioToolbox
import Combine
import CoreAudio
import Darwin

public struct OutputDevice: Identifiable, Equatable, Sendable {
    public var id: String { uid }
    public let uid: String
    public let name: String
    public let sampleRate: Double
    public let channels: UInt32
    let deviceID: AudioDeviceID

    public var isSupportedForStageA: Bool {
        channels == 2 && sampleRate.isFinite && (sampleRate == 44_100 || sampleRate == 48_000)
    }
}

func discoverOutputDevices(
    ids: some Sequence<AudioDeviceID>,
    readDevice: (AudioDeviceID) throws -> OutputDevice?
) -> [OutputDevice] {
    ids.compactMap { id in
        do { return try readDevice(id) }
        catch { return nil }
    }
}

enum DeviceOutputEvent: Sendable { case deviceChanged, defaultChanged, configurationChanged, sleep, renderFault }
struct DeviceOutputSnapshot {
    var deviceID: AudioDeviceID
    var sampleRate: Double
    var channels: UInt32
    var isStereo: Bool
}

enum DeviceOutputError: LocalizedError {
    case unavailable, unsupportedFormat, stale, changed, invalidBuffer, osStatus(OSStatus)
    var errorDescription: String? {
        switch self {
        case .unavailable: "選択した出力機器を利用できません。"
        case .unsupportedFormat: "指定レートの2チャンネル・左右配置を確認できません。"
        case .stale: "出力機器を確認して、もう一度開始してください。"
        case .changed: "機器・音声構成の変更またはスリープにより停止しました。"
        case .invalidBuffer: "音声バッファの不整合により停止しました。"
        case .osStatus(let status): "音声出力の確認に失敗しました（OSStatus: \(status)）。"
        }
    }
}

/// The injected boundary replaces hardware operations only; lifecycle and readback validation remain here.
@MainActor protocol DeviceOutputBackend: AnyObject, Sendable {
    var callbackCount: UInt64 { get }
    func availableDevices() throws -> [OutputDevice]
    func configure(device: OutputDevice, sampleRate: Double,
                   onEvent: @escaping @MainActor @Sendable (DeviceOutputEvent) -> Void) throws
    func snapshot() throws -> DeviceOutputSnapshot
    func start() throws
    func stop()
    func dispose()
    func resetDiagnostics()
}

@MainActor public final class DeviceOutput: ObservableObject {
    @Published public private(set) var isRunning = false
    @Published public private(set) var selectedUID: String?
    @Published public private(set) var lastError: String?
    public var callbackCount: UInt64 { backend.callbackCount }
    /// Last explicitly validated device ID; nil once preparation is invalidated.
    public var verifiedDeviceID: UInt32? { prepared?.deviceID }
    private let backend: any DeviceOutputBackend
    private var generation: UInt64 = 0
    private var prepared: OutputDevice?
    private var requestedRate: Double = 0

    public convenience init() { self.init(backend: CoreAudioOutputBackend()) }
    init(backend: any DeviceOutputBackend) { self.backend = backend }
    deinit {
        let backend = backend
        Task { @MainActor in backend.dispose() }
    }

    public static func availableDevices() throws -> [OutputDevice] {
        try CoreAudioOutputBackend.devices()
    }

    public func prepare(uid: String, sampleRate: Double) throws {
        stop()
        backend.resetDiagnostics()
        lastError = nil
        do {
            guard sampleRate.isFinite, sampleRate == 44100 || sampleRate == 48000 else {
                throw DeviceOutputError.unsupportedFormat
            }
            let matches = try backend.availableDevices().filter { $0.uid == uid }
            guard !uid.isEmpty, matches.count == 1, let device = matches.first else {
                throw DeviceOutputError.unavailable
            }
            guard device.channels == 2, device.sampleRate == sampleRate else {
                throw DeviceOutputError.unsupportedFormat
            }
            let ticket = generation
            try backend.configure(device: device, sampleRate: sampleRate) { [weak self] event in
                guard let self, self.generation == ticket else { return }
                self.stop()
                self.lastError = (event == .renderFault ? DeviceOutputError.invalidBuffer : .changed).localizedDescription
            }
            guard generation == ticket else { throw DeviceOutputError.stale }
            try validate(device: device, sampleRate: sampleRate)
            prepared = device
            requestedRate = sampleRate
            selectedUID = uid
        } catch { fail(error); throw error }
    }

    public func startSilence() throws {
        do {
            guard !isRunning, let device = prepared else { throw DeviceOutputError.stale }
            let ticket = generation
            try validate(device: device, sampleRate: requestedRate)
            try backend.start()
            guard generation == ticket else { throw DeviceOutputError.stale }
            // Starting the OS graph is another boundary at which the route may change.
            try validate(device: device, sampleRate: requestedRate)
            isRunning = true
        } catch { fail(error); throw error }
    }

    public func stop() {
        generation &+= 1
        backend.stop()
        backend.dispose()
        prepared = nil
        selectedUID = nil
        isRunning = false
    }
    public func dispose() { stop() }

    private func fail(_ error: Error) {
        stop()
        lastError = error.localizedDescription
    }
    private func validate(device: OutputDevice, sampleRate: Double) throws {
        guard try backend.availableDevices().contains(where: {
            $0.uid == device.uid && $0.deviceID == device.deviceID && $0.channels == 2 && $0.sampleRate == sampleRate
        }) else { throw DeviceOutputError.unavailable }
        let actual = try backend.snapshot()
        guard actual.deviceID == device.deviceID else { throw DeviceOutputError.changed }
        guard actual.channels == 2, actual.isStereo, actual.sampleRate == sampleRate else {
            throw DeviceOutputError.unsupportedFormat
        }
    }
}

@MainActor private final class CoreAudioOutputBackend: DeviceOutputBackend {
    private var engine: AVAudioEngine?
    private var source: AVAudioSourceNode?
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var configurationObserver: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?
    private var diagnosticTimer: DispatchSourceTimer?
    private var renderState: SilenceRenderState?
    var callbackCount: UInt64 { renderState?.callbackCount ?? 0 }

    func availableDevices() throws -> [OutputDevice] { try Self.devices() }

    static func devices() throws -> [OutputDevice] {
        var address = property(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size))
        guard size % UInt32(MemoryLayout<AudioDeviceID>.size) == 0, size <= 65536 else {
            throw DeviceOutputError.unavailable
        }
        guard size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        let capacity = size
        try ids.withUnsafeMutableBytes { bytes in
            try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, bytes.baseAddress!))
        }
        guard size <= capacity, size % 4 == 0 else { throw DeviceOutputError.unavailable }
        return discoverOutputDevices(ids: ids.prefix(Int(size) / MemoryLayout<AudioDeviceID>.size)) { id in
            let alive: UInt32 = try scalar(id, kAudioDevicePropertyDeviceIsAlive, initial: 0)
            guard alive != 0 else { return nil }
            let channels = try channelCount(id)
            guard channels > 0 else { return nil }
            let uid = try string(id, kAudioDevicePropertyDeviceUID)
            let name = try string(id, kAudioObjectPropertyName)
            let rate: Double = try scalar(id, kAudioDevicePropertyNominalSampleRate, initial: 0)
            return OutputDevice(uid: uid, name: name, sampleRate: rate, channels: channels, deviceID: id)
        }
    }

    func configure(device: OutputDevice, sampleRate: Double,
                   onEvent: @escaping @MainActor @Sendable (DeviceOutputEvent) -> Void) throws {
        dispose()
        let graph = AVAudioEngine()
        engine = graph // Retain partial construction so every throwing path can dispose it.
        guard let unit = graph.outputNode.audioUnit else { throw DeviceOutputError.unavailable }
        var id = device.deviceID
        try Self.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                            kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout.size(ofValue: id))))
        let actual = try snapshot()
        guard actual.deviceID == id, actual.sampleRate == sampleRate, actual.channels == 2, actual.isStereo else {
            throw DeviceOutputError.unsupportedFormat
        }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
            throw DeviceOutputError.unsupportedFormat
        }
        let state = SilenceRenderState()
        renderState = state
        // The closure owns one immutable state reference. Rendering only touches atomic primitive
        // storage; its last reference is released on the control side after stop and detach.
        let node = AVAudioSourceNode(format: format) { @Sendable isSilence, _, frames, buffers in
            isSilence.pointee = true
            return state.render(frames: frames, buffers: buffers)
        }
        source = node
        graph.attach(node)
        graph.connect(node, to: graph.outputNode, format: format)
        graph.prepare()

        // Core Audio notifications run on the explicit main queue. They never execute on our render callback.
        for selector in [kAudioDevicePropertyDeviceIsAlive, kAudioDevicePropertyNominalSampleRate] {
            try listen(device.deviceID, Self.property(selector), event: .deviceChanged, onEvent: onEvent)
        }
        for selector in [kAudioDevicePropertyStreamConfiguration, kAudioDevicePropertyPreferredChannelsForStereo] {
            try listen(device.deviceID, Self.property(selector, scope: kAudioObjectPropertyScopeOutput),
                       event: .configurationChanged, onEvent: onEvent)
        }
        // Some built-in devices keep their UID while a jack/data-source change routes to speakers.
        // These controls are optional and may be exposed on the main element or either stereo channel.
        for selector in [kAudioDevicePropertyDataSource, kAudioDevicePropertyJackIsConnected] {
            for element: UInt32 in 0...2 {
                var address = Self.property(selector, scope: kAudioObjectPropertyScopeOutput)
                address.mElement = element
                if AudioObjectHasProperty(device.deviceID, &address) {
                    try listen(device.deviceID, address, event: .deviceChanged, onEvent: onEvent)
                }
            }
        }
        try listen(AudioObjectID(kAudioObjectSystemObject), Self.property(kAudioHardwarePropertyDevices),
                   event: .deviceChanged, onEvent: onEvent)
        try listen(AudioObjectID(kAudioObjectSystemObject), Self.property(kAudioHardwarePropertyDefaultOutputDevice),
                   event: .defaultChanged, onEvent: onEvent)
        // Always hop asynchronously: Apple forbids tearing down the engine within its configuration notification.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: graph, queue: nil
        ) { _ in Task { @MainActor in onEvent(.configurationChanged) } }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: nil
        ) { _ in Task { @MainActor in onEvent(.sleep) } }
        // One bounded control-side poll; render errors never allocate a Task or send a notification.
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(20), repeating: .milliseconds(20))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard self?.renderState?.hasFault == true else { return }
                onEvent(.renderFault)
            }
        }
        diagnosticTimer = timer
        timer.resume()
    }

    func snapshot() throws -> DeviceOutputSnapshot {
        guard let graph = engine, let unit = graph.outputNode.audioUnit else { throw DeviceOutputError.unavailable }
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout.size(ofValue: id))
        try Self.check(AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                            kAudioUnitScope_Global, 0, &id, &size))
        guard size == MemoryLayout.size(ofValue: id), id != kAudioObjectUnknown else { throw DeviceOutputError.unavailable }
        let format = graph.outputNode.outputFormat(forBus: 0)
        let stereo = try Self.stereoChannels(id)
        return DeviceOutputSnapshot(deviceID: id, sampleRate: format.sampleRate,
                                    channels: format.channelCount, isStereo: stereo)
    }
    func start() throws {
        guard let engine else { throw DeviceOutputError.stale }
        try engine.start()
        guard engine.isRunning else { throw DeviceOutputError.unavailable }
    }
    func stop() { engine?.stop() }
    func resetDiagnostics() { renderState = nil }
    func dispose() {
        engine?.stop()
        diagnosticTimer?.cancel()
        diagnosticTimer = nil
        for (id, originalAddress, block) in listeners {
            var address = originalAddress
            AudioObjectRemovePropertyListenerBlock(id, &address, .main, block)
        }
        listeners.removeAll()
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
        configurationObserver = nil
        sleepObserver = nil
        if let source { engine?.detach(source) }
        source = nil
        engine = nil
        // Retain the stopped state until the next prepare: diagnostics must detect any late callbacks.
    }

    private func listen(_ id: AudioObjectID, _ originalAddress: AudioObjectPropertyAddress,
                        event: DeviceOutputEvent,
                        onEvent: @escaping @MainActor @Sendable (DeviceOutputEvent) -> Void) throws {
        var address = originalAddress
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            // A hop also avoids mutating/removing the listener list during Core Audio's delivery.
            Task { @MainActor in onEvent(event) }
        }
        try Self.check(AudioObjectAddPropertyListenerBlock(id, &address, .main, block))
        listeners.append((id, address, block))
    }
    private static func property(_ selector: AudioObjectPropertySelector,
                                 scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
    private static func check(_ status: OSStatus) throws {
        guard status == noErr else { throw DeviceOutputError.osStatus(status) }
    }
    private static func scalar<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, initial: T) throws -> T {
        var address = property(selector)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        try check(withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0)
        })
        guard size == MemoryLayout<T>.size else { throw DeviceOutputError.unavailable }
        return value
    }
    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        // Core Audio's CFString properties return retained values, released by ARC on the control side.
        var address = property(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try check(AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value))
        guard let value else { throw DeviceOutputError.unavailable }
        let ownedValue = value.takeRetainedValue()
        guard size == MemoryLayout<Unmanaged<CFString>?>.size else { throw DeviceOutputError.unavailable }
        return ownedValue as String
    }
    private static func stereoChannels(_ id: AudioDeviceID) throws -> Bool {
        var address = property(kAudioDevicePropertyPreferredChannelsForStereo, scope: kAudioObjectPropertyScopeOutput)
        var channels: (UInt32, UInt32) = (0, 0)
        var size: UInt32 = 8
        try check(AudioObjectGetPropertyData(id, &address, 0, nil, &size, &channels))
        return size == 8 && channels.0 == 1 && channels.1 == 2
    }
    private static func channelCount(_ id: AudioDeviceID) throws -> UInt32 {
        var address = property(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size))
        let headerBytes = MemoryLayout<AudioBufferList>.offset(of: \.mBuffers)!
        guard size >= headerBytes, size <= 65536 else { throw DeviceOutputError.unavailable }
        let capacity = size
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        try check(AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw))
        guard size <= capacity, size >= headerBytes else { throw DeviceOutputError.unavailable }
        let list = raw.assumingMemoryBound(to: AudioBufferList.self)
        let maximumBuffers = (Int(size) - MemoryLayout<AudioBufferList>.offset(of: \.mBuffers)!) / MemoryLayout<AudioBuffer>.stride
        guard list.pointee.mNumberBuffers <= maximumBuffers else { throw DeviceOutputError.unavailable }
        var count: UInt32 = 0
        for buffer in UnsafeMutableAudioBufferListPointer(list) {
            let addition = count.addingReportingOverflow(buffer.mNumberChannels)
            guard !addition.overflow else { throw DeviceOutputError.unavailable }
            count = addition.partialValue
        }
        return count
    }
}

/// Only the explicitly connected Float32 noninterleaved stereo format is accepted.
/// Framework-owned buffer allocation is trusted; lengths and frame work are bounded before memory access.
nonisolated func renderDeviceSilence(frames: UInt32, buffers: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
    guard frames <= 16384, buffers.pointee.mNumberBuffers == 2 else { return kAudio_ParamError }
    let list = UnsafeMutableAudioBufferListPointer(buffers)
    let expectedBytes = frames * UInt32(MemoryLayout<Float>.size)
    var valid = true
    for buffer in list {
        guard buffer.mNumberChannels == 1, buffer.mDataByteSize == expectedBytes,
              let data = buffer.mData else { valid = false; continue }
        memset(data, 0, Int(expectedBytes))
    }
    return valid ? noErr : kAudio_ParamError
}

/// @unchecked Sendable is limited to two immutable, aligned pointer identities. Every concurrent
/// access to their pointees uses OSAtomic. Allocation/deallocation occurs outside render; the source
/// closure retains this object for its entire lifetime. This macOS 14.2 spike uses deprecated OSAtomic
/// instead of a new dependency; a later approved C render boundary should use C11 atomics.
final class SilenceRenderState: @unchecked Sendable {
    private let count = UnsafeMutablePointer<Int64>.allocate(capacity: 1)
    private let fault = UnsafeMutablePointer<UInt32>.allocate(capacity: 1)
    init() { count.initialize(to: 0); fault.initialize(to: 0) }
    deinit { count.deinitialize(count: 1); count.deallocate(); fault.deinitialize(count: 1); fault.deallocate() }
    var callbackCount: UInt64 { UInt64(bitPattern: OSAtomicAdd64Barrier(0, count)) }
    var hasFault: Bool { OSAtomicOr32Barrier(0, fault) != 0 }
    func render(frames: UInt32, buffers: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        OSAtomicIncrement64Barrier(count)
        let status = renderDeviceSilence(frames: frames, buffers: buffers)
        if status != noErr { OSAtomicOr32Barrier(1, fault) }
        return status
    }
}
