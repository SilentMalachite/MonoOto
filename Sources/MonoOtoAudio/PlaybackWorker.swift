import Foundation
import MonoOtoCore
import MonoOtoRealtime

/// This non-Sendable source is created, used, and destroyed on the worker queue.
internal protocol PlaybackWorkerSource: AnyObject {
    var metadata: PlaybackWorker.Metadata { get }
    var cancellationWarning: Bool { get }
    func read(maxFrames: Int) throws -> [Float]
    func set(_ settings: PlaybackWorker.Settings) throws
    func seek(sourceFrame: Int64) throws
}

private final class WorkerSourceRelease: @unchecked Sendable {
    var source: (any PlaybackWorkerSource)?
    init(_ source: (any PlaybackWorkerSource)?) { self.source = source }
}

private final class PipelineWorkerSource: PlaybackWorkerSource {
    let pipeline: AudioFilePipeline
    init(_ pipeline: AudioFilePipeline) { self.pipeline = pipeline }
    var metadata: PlaybackWorker.Metadata {
        .init(sourceFrameCount: pipeline.sourceFrameCount, sourceRate: pipeline.sourceRate,
              channelCount: pipeline.channelCount, outputRate: pipeline.outputRate, latencyFrames: pipeline.latencyFrames)
    }
    var cancellationWarning: Bool { pipeline.cancellationWarning }
    func read(maxFrames: Int) throws -> [Float] { try pipeline.read(maxFrames: maxFrames) }
    func set(_ settings: PlaybackWorker.Settings) throws {
        try pipeline.set(mode: settings.mode, parameters: settings.parameters, gainDB: settings.gainDB)
    }
    func seek(sourceFrame: Int64) throws { try pipeline.seek(sourceFrame: sourceFrame) }
}

private final class WorkerExecutionLease: @unchecked Sendable {}

/// A dispatch block captures only this wrapper. Release the operation's worker
/// references BEFORE relinquishing the lease, independently of closure capture order.
private final class WorkerOperation: @unchecked Sendable {
    private var body: (@Sendable () -> Void)?
    private var lease: WorkerExecutionLease?
    init(body: @escaping @Sendable () -> Void, lease: WorkerExecutionLease) {
        self.body = body; self.lease = lease
    }
    func run() { body?() }
    deinit { withExtendedLifetime(lease) { body = nil }; lease = nil }
}

/// Only the mailbox/snapshot crosses threads. The source and pending PCM never do.
/// The owner is held until producer completion, in addition to its control/render owners.
internal final class PlaybackWorker: @unchecked Sendable {
    struct Metadata: Sendable, Equatable {
        let sourceFrameCount: Int64
        let sourceRate: Double
        let channelCount: Int
        let outputRate: Double
        let latencyFrames: Int
        var durationSeconds: Double { Double(sourceFrameCount) / sourceRate }
    }
    struct Settings: Sendable, Equatable {
        var mode: ListeningMode
        var parameters: EncoderParameters
        var gainDB: Float?
        static let initial = Settings(mode: .mono, parameters: .init(strength: 0.35, cutoffHz: 1500), gainDB: -18)
        func validate(channelCount: Int? = nil) throws {
            guard parameters.strength.isFinite, (0...0.6).contains(parameters.strength) else { throw EncoderError.invalidStrength }
            guard parameters.cutoffHz.isFinite, (800...4000).contains(parameters.cutoffHz) else { throw EncoderError.invalidCutoffHz }
            if let gainDB, !gainDB.isFinite || gainDB > 0 { throw AudioFilePipelineError.invalidGain }
            if channelCount == 1, mode == .leftOnly || mode == .rightOnly { throw AudioFilePipelineError.stereoRequired }
        }
    }
    struct Snapshot: Sendable {
        let sessionID: UInt64
        var metadata: Metadata?
        var started = false
        var ready = false
        var parked = false
        var finished = false
        var producerDone = false
        var totalAccepted: UInt64 = 0
        var pendingCount = 0
        var cancellationWarning = false
        var error: String?
        var parkedTicket: UInt64?
        var resumedTicket: UInt64?
    }
    enum Failure: Error { case interrupted, alreadyPrepared, sourceFailed }
    typealias Push = @Sendable (OpaquePointer, UnsafeBufferPointer<Float>) -> UInt32

    private let owner: PlaybackRenderOwner
    private let work = DispatchQueue(label: "MonoOto.PlaybackWorker", qos: .userInitiated)
    private let lock = NSLock()
    private var published: Snapshot
    private var executionLease = WorkerExecutionLease()
    private var requestedStop = false
    private var controlScheduled = false
    private var requestedPark: UInt64?
    private var requestedResume: UInt64?
    private var latestSettings: Settings?
    private var didPrepare = false
    private let initialSettings: Settings
    private let sourceFrame: Int64
    private let factory: @Sendable () throws -> any PlaybackWorkerSource
    private let push: Push
    private let automaticTicks: Bool
    private let afterFinishedForTesting: (@Sendable () -> Void)?

    // Dedicated queue only, including final source release.
    private var source: (any PlaybackWorkerSource)?
    private var timer: DispatchSourceTimer?
    private var pending: [Float] = []
    private var offset = 0
    private var accepted: UInt64 = 0
    private var eof = false
    private var parked = false
    private var finished = false
    private var preparation: CheckedContinuation<Metadata, Error>?

    convenience init(sessionID: UInt64, owner: PlaybackRenderOwner, settings: Settings = .initial,
                     sourceFrame: Int64 = 0, automaticTicks: Bool = true,
                     factory: @escaping @Sendable () throws -> AudioFilePipeline) {
        self.init(sessionID: sessionID, owner: owner, settings: settings, sourceFrame: sourceFrame,
                  automaticTicks: automaticTicks, sourceFactory: { PipelineWorkerSource(try factory()) })
    }
    init(sessionID: UInt64, owner: PlaybackRenderOwner, settings: Settings = .initial,
         sourceFrame: Int64 = 0, automaticTicks: Bool = true,
         sourceFactory: @escaping @Sendable () throws -> any PlaybackWorkerSource,
         afterFinishedForTesting: (@Sendable () -> Void)? = nil,
         push: @escaping Push = { mo_queue_push($0, $1.baseAddress, UInt32($1.count)) }) {
        self.owner = owner; initialSettings = settings; self.sourceFrame = sourceFrame
        self.automaticTicks = automaticTicks; factory = sourceFactory; self.push = push
        self.afterFinishedForTesting = afterFinishedForTesting
        published = Snapshot(sessionID: sessionID)
    }

    deinit {
        // An abandoned controller must not perform AVAudioFile/DSP final release
        // on MainActor. A running queue operation retains self until it returns.
        owner.silence()
        timer?.setEventHandler {}; timer?.cancel()
        if source != nil {
            // Abandonment only: normal completion already destroyed the source,
            // and schedules no work after completionConfirmed becomes true.
            let release = WorkerSourceRelease(source)
            source = nil
            work.async { release.source = nil }
        }
    }

    /// Completion requires every queued/executing dispatch and timer closure to
    /// relinquish ownership. finished alone is published from inside such a closure.
    var completionConfirmed: Bool {
        lock.withLock { published.finished && isKnownUniquelyReferenced(&executionLease) }
    }

    @discardableResult private func enqueue(_ body: @escaping @Sendable () -> Void) -> Bool {
        let operation: WorkerOperation? = lock.withLock {
            guard !published.finished else { return nil }
            return WorkerOperation(body: body, lease: executionLease)
        }
        guard let operation else { return false }
        work.async { operation.run() }
        return true
    }

    func snapshot() -> Snapshot { lock.withLock { published } }
    func updateSettings(_ settings: Settings) throws {
        try lock.withLock {
            try settings.validate(channelCount: published.metadata?.channelCount)
            guard !requestedStop, !published.finished else { throw Failure.interrupted }
            latestSettings = settings
        }
    }
    func requestPark(ticket: UInt64) {
        lock.withLock { if !requestedStop { requestedPark = max(requestedPark ?? ticket, ticket) } }
        scheduleControl()
    }
    func requestStop() {
        owner.silence()
        lock.withLock { requestedStop = true; latestSettings = nil }
        scheduleControl()
    }
    private func scheduleControl() {
        let schedule = lock.withLock { if controlScheduled || published.finished { return false }; controlScheduled = true; return true }
        guard schedule else { return }
        enqueue { [self] in
            lock.withLock { controlScheduled = false }
            _ = processControl()
        }
    }
    func prepare(prefill: Bool = true) async throws -> Metadata {
        try await withCheckedThrowingContinuation { continuation in
            let enqueued = enqueue { [self] in
                guard !didPrepare else { continuation.resume(throwing: Failure.alreadyPrepared); return }
                didPrepare = true
                lock.withLock { published.started = true }
                guard !lock.withLock({ requestedStop }) else {
                    finish(); continuation.resume(throwing: Failure.interrupted); return
                }
                do {
                    source = try factory()
                    let metadata = source!.metadata
                    try initialSettings.validate(channelCount: metadata.channelCount)
                    try source!.set(initialSettings)
                    // Applying the initial gain before seek makes the new session start
                    // at that setting, while seek resets SRC/DSP/fade exactly once.
                    try source!.seek(sourceFrame: sourceFrame)
                    lock.withLock { published.metadata = metadata }
                    if prefill {
                        preparation = continuation
                        startTimer()
                        pump()
                    } else {
                        parked = true
                        lock.withLock { published.parked = true }
                        continuation.resume(returning: metadata)
                    }
                } catch {
                    fail(error); continuation.resume(throwing: Failure.sourceFailed)
                }
            }
            if !enqueued { continuation.resume(throwing: Failure.interrupted) }
        }
    }
    func park(ticket: UInt64) async {
        requestPark(ticket: ticket)
        await withCheckedContinuation { continuation in
            let enqueued = enqueue { [self] in _ = processControl(); continuation.resume() }
            if !enqueued { continuation.resume() }
        }
    }
    /// The controller posts into the bounded control mailbox and polls the acknowledgement.
    /// It must not await a dispatch closure behind an uncooperative source read.
    func requestResume(ticket: UInt64) {
        lock.withLock {
            guard !requestedStop, ticket >= (published.resumedTicket ?? 0) else { return }
            requestedResume = max(requestedResume ?? ticket, ticket)
        }
        scheduleControl()
    }
    func resume(ticket: UInt64) async {
        requestResume(ticket: ticket)
        await withCheckedContinuation { continuation in
            let enqueued = enqueue { [self] in _ = processControl(); continuation.resume() }
            if !enqueued { continuation.resume() }
        }
    }
    func stop() async {
        requestStop()
        await withCheckedContinuation { continuation in
            let enqueued = enqueue { [self] in finish(); continuation.resume() }
            if !enqueued { continuation.resume() }
        }
    }
    func tickForTesting() async {
        await withCheckedContinuation { continuation in
            let enqueued = enqueue { [self] in pump(); continuation.resume() }
            if !enqueued { continuation.resume() }
        }
    }
    private func startTimer() {
        guard automaticTicks, timer == nil, !finished else { return }
        let timer = DispatchSource.makeTimerSource(queue: work)
        timer.schedule(deadline: .now(), repeating: .milliseconds(2), leeway: .microseconds(200))
        let lease = lock.withLock { executionLease }
        timer.setEventHandler { [weak self, lease] in
            withExtendedLifetime(lease) { self?.pump() }
        }
        self.timer = timer
        timer.resume()
    }
    private func processControl() -> Bool {
        let control = lock.withLock { () -> (Bool, UInt64?, UInt64?) in
            if !requestedStop, let ticket = requestedResume, ticket >= (requestedPark ?? 0) {
                requestedResume = nil; requestedPark = nil
                return (false, nil, ticket)
            }
            return (requestedStop, requestedPark, nil)
        }
        if control.0 { finish(); return false }
        if let ticket = control.2 {
            guard !finished, !owner.stats.silenced else { return false }
            parked = false
            startTimer()
            lock.withLock {
                published.parked = false; published.parkedTicket = nil; published.resumedTicket = ticket
            }
        }
        if let ticket = control.1 {
            parked = true
            lock.withLock { published.parked = true; published.parkedTicket = ticket }
            if let preparation { self.preparation = nil; preparation.resume(throwing: Failure.interrupted) }
            return false
        }
        return !finished && !parked
    }
    private func pump() {
        guard processControl(), source != nil else { return }
        let stats = owner.stats
        guard !stats.silenced, !stats.faulted else { fail(); return }
        do {
            if offset == pending.count, !eof {
                pending.removeAll(keepingCapacity: true); offset = 0
                let outstanding = accepted &- stats.rendered_frames
                guard outstanding <= 4096 else { fail(); return }
                let room = 4096 - Int(outstanding)
                guard room > 0 else { return }
                if let settings = lock.withLock({ let settings = latestSettings; latestSettings = nil; return settings }) {
                    try source!.set(settings)
                }
                guard processControl() else { return }
                pending = try source!.read(maxFrames: min(1024, room))
                guard pending.count <= min(1024, room) else { fail(); return }
                eof = pending.isEmpty
                lock.withLock {
                    published.pendingCount = pending.count
                    published.cancellationWarning = source!.cancellationWarning
                    // EOF is a session fact, including when a park request arrived
                    // during this final read. No pending PCM exists at this point.
                    if eof { published.producerDone = true; published.ready = true }
                }
                // An in-flight read may finish after pause/stop. Preserve on pause,
                // discard on stop; never issue a push before checking the mailbox.
                guard processControl() else { return }
            }
            if offset < pending.count {
                let remaining = pending.count - offset
                let count = pending.withUnsafeBufferPointer { buffer in
                    push(owner.queue, UnsafeBufferPointer(start: buffer.baseAddress!.advanced(by: offset), count: remaining))
                }
                guard count <= remaining else { fail(); return }
                accepted += UInt64(count); offset += Int(count)
                lock.withLock { published.totalAccepted = accepted; published.pendingCount = pending.count - offset }
                guard !owner.stats.silenced, !owner.stats.faulted else { fail(); return }
                guard processControl() else { return }
            }
            let done = eof && offset == pending.count
            lock.withLock {
                published.producerDone = done
                if accepted >= 2048 || done { published.ready = true }
            }
            if snapshot().ready, let preparation, let metadata = snapshot().metadata {
                self.preparation = nil; preparation.resume(returning: metadata)
            }
        } catch { fail(error) }
    }
    private func fail(_ error: Error? = nil) {
        owner.silence()
        let message: String
        switch error as? AudioFilePipelineError {
        case .unsupportedContainer: message = "WAVまたはAIFF形式の音源を選択してください。"
        case .unsupportedPCM: message = "PCM 16/24 bitまたはFloat32の音源に対応しています。"
        case .unsupportedSampleRate: message = "44.1 kHzまたは48 kHzの音源と出力に対応しています。"
        case .unsupportedChannelCount: message = "モノラルまたはステレオの音源に対応しています。"
        case .invalidFile: message = "音源ファイルを開けませんでした。"
        case .stereoRequired: message = "左右単独の確認にはステレオ音源が必要です。"
        case .nonfiniteAudio: message = "音源に不正なサンプルが含まれています。"
        default: message = "音源の処理に失敗しました。"
        }
        lock.withLock { published.error = message }
        finish()
    }
    private func finish() {
        guard !finished else { return }
        finished = true
        timer?.setEventHandler {}; timer?.cancel(); timer = nil
        source = nil
        pending.removeAll(keepingCapacity: false); offset = 0
        lock.withLock { published.finished = true; published.pendingCount = 0; latestSettings = nil }
        afterFinishedForTesting?()
        if let preparation {
            self.preparation = nil
            preparation.resume(throwing: snapshot().error == nil ? Failure.interrupted : Failure.sourceFailed)
        }
    }
}
