import Combine
import Foundation
import MonoOtoCore
import MonoOtoRealtime

public enum PlaybackControllerError: LocalizedError {
    case selectionRequired, sourceRequired, interrupted, invalidSeek, cleanupTimeout, sourceFailed
    public var errorDescription: String? {
        switch self {
        case .selectionRequired: "出力機器と聞こえる耳を選択してください。"
        case .sourceRequired: "音源ファイルを選択してください。"
        case .interrupted: "新しい操作により処理を取り消しました。"
        case .invalidSeek: "再生位置が音源の範囲外です。"
        case .cleanupTimeout: "音声処理の終了を確認できません。新しい再生を停止しています。"
        case .sourceFailed: "音源の処理に失敗しました。"
        }
    }
}

/// MainActor owns control and display state; only PlaybackWorker touches a pipeline.
/// One driver serializes preparation/disposal. A single replaceable request bounds backlog.
@MainActor public final class PlaybackController: ObservableObject {
    @Published public private(set) var phase: PlaybackPhase = .stopped
    @Published public private(set) var positionSeconds: Double = 0
    @Published public private(set) var durationSeconds: Double = 0
    @Published public private(set) var channelCount: Int = 0
    @Published public private(set) var cancellationWarning = false
    @Published public private(set) var lastError: String?
    @Published public private(set) var selectedUID: String?
    @Published public private(set) var selectedEar: HearingEar?
    @Published public private(set) var mode: ListeningMode = .mono
    @Published public private(set) var parameters = EncoderParameters(strength: 0.35, cutoffHz: 1500)
    @Published public private(set) var gainDB: Float? = -18

    private enum Input: Sendable { case file(URL), tone }
    private enum Operation { case open(URL), play, pause, stop, seek(Double, Bool), tone }
    private final class Request {
        let id: UInt64
        let operation: Operation
        var error: Error?
        var completed = false
        init(id: UInt64, operation: Operation) { self.id = id; self.operation = operation }
    }
    @MainActor private final class Session {
        let id: UInt64
        let owner: PlaybackRenderOwner
        let worker: PlaybackWorker
        let segmentStart: Double
        let uid: String?
        let ear: HearingEar
        // At most one uncooperative preparation exists, retained with its session.
        var preparationTask: Task<Void, Never>?
        var outputPrepared = false
        var metadata: PlaybackWorker.Metadata?
        var paused = false
        var drainDeadline: TimeInterval?
        var lastRendered: UInt64 = 0
        var lastProgress: TimeInterval
        var underrunTimes: [TimeInterval] = []
        var underrunBaseline: UInt64 = 0
        init(id: UInt64, owner: PlaybackRenderOwner, worker: PlaybackWorker,
             segmentStart: Double, uid: String?, ear: HearingEar, now: TimeInterval) {
            self.id = id; self.owner = owner; self.worker = worker; self.segmentStart = segmentStart
            self.uid = uid; self.ear = ear
            lastProgress = now
        }
    }
    private let output: DeviceOutput
    private let devices: @MainActor () throws -> [OutputDevice]
    private let now: @MainActor () -> TimeInterval
    private let pipelineFactory: @Sendable (URL, Double) throws -> AudioFilePipeline
    private let state = PlaybackState()
    @Published private var confirmationActive = false
    public var canSeek: Bool { !confirmationActive && fileMetadata != nil }
    private var input: Input?
    private var fileMetadata: PlaybackWorker.Metadata?
    private var sourcePosition: Double = 0
    private var settings = PlaybackWorker.Settings.initial
    private var session: Session?
    private var nextSessionID: UInt64 = 0
    private var operationID: UInt64 = 0
    private var pending: Request?
    private var active: Request?
    private var driver: Task<Void, Never>?
    private var timer: DispatchSourceTimer?
    private var cleanupBlocked = false

    public convenience init() { self.init(output: DeviceOutput(), devices: { try DeviceOutput.availableDevices() }) }
    init(output: DeviceOutput, devices: @escaping @MainActor () throws -> [OutputDevice],
         now: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         automaticPolling: Bool = true,
         pipelineFactory: @escaping @Sendable (URL, Double) throws -> AudioFilePipeline = {
             try AudioFilePipeline(url: $0, outputRate: $1)
         }) {
        self.output = output; self.devices = devices; self.now = now
        self.pipelineFactory = pipelineFactory
        output.onFailure = { [weak self] message in self?.failAndStop(message) }
        if automaticPolling {
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now() + .milliseconds(20), repeating: .milliseconds(20))
            timer.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.poll() } }
            self.timer = timer; timer.resume()
        }
    }

    deinit {
        timer?.cancel()
        let session = session
        let output = output
        session?.owner.silence(); session?.worker.requestStop()
        // Exactly one shutdown owner survives the controller, until both users relinquish it.
        let release: @MainActor @Sendable () -> Void = {
            output.onFailure = nil
            output.stop()
            Task { @MainActor in
                while session?.worker.completionConfirmed == false {
                    try? await Task.sleep(for: .milliseconds(2))
                }
                await session?.preparationTask?.value
                while true {
                    do { try await output.waitUntilStopped(); break }
                    catch { try? await Task.sleep(for: .milliseconds(20)) }
                }
                withExtendedLifetime(session) {}
            }
        }
        if Thread.isMainThread { MainActor.assumeIsolated { release() } }
        else { Task { @MainActor in release() } }
    }

    public func open(url: URL) async throws { try await submit(.open(url), destructive: true) }
    public func play() async throws {
        guard selectedUID != nil, selectedEar != nil else { throw rejected(.selectionRequired) }
        guard input != nil || session?.paused == true else { throw rejected(.sourceRequired) }
        if phase == .running { return }
        if let request = pending ?? active, case .play = request.operation, request.id == operationID {
            try await awaitRequest(request); return
        }
        try await submit(.play, destructive: false)
    }
    public func pause() {
        guard session != nil, phase == .running || phase == .preparing else { return }
        session?.paused = true
        let request = enqueue(.pause, destructive: false)
        session?.owner.hold(); session?.worker.requestPark(ticket: request.id)
        output.pausePlayback()
    }
    public func stop() { _ = enqueue(.stop, destructive: true) }
    public func seek(seconds: Double) async throws {
        guard canSeek, let metadata = fileMetadata, input != nil,
              seconds.isFinite, seconds >= 0, seconds <= metadata.durationSeconds else {
            throw rejected(.invalidSeek)
        }
        try await submit(.seek(seconds, phase == .running), destructive: true)
    }
    public func selectOutput(uid: String, ear: HearingEar) {
        _ = enqueue(.stop, destructive: true)
        selectedUID = uid; selectedEar = ear
    }
    public func set(mode: ListeningMode, parameters: EncoderParameters, gainDB: Float?) throws {
        let candidate = PlaybackWorker.Settings(mode: mode, parameters: parameters, gainDB: gainDB)
        do {
            try candidate.validate(channelCount: channelCount == 0 ? nil : channelCount)
            if let session, !session.owner.stats.silenced, !session.worker.snapshot().finished {
                try session.worker.updateSettings(candidate)
            }
            settings = candidate; self.mode = mode; self.parameters = parameters; self.gainDB = gainDB
        } catch {
            lastError = "設定値または音源のチャンネル数を確認してください。"
            throw error
        }
    }
    public func playConfirmationTone() async throws {
        guard selectedUID != nil, selectedEar != nil else { throw rejected(.selectionRequired) }
        try await submit(.tone, destructive: true)
    }
    public func waitUntilSettled() async { if let driver { await driver.value } }

    private func submit(_ operation: Operation, destructive: Bool) async throws {
        let request = enqueue(operation, destructive: destructive)
        try await awaitRequest(request)
    }
    private func awaitRequest(_ request: Request) async throws {
        if let driver { await driver.value }
        guard request.completed, request.id == operationID else { throw PlaybackControllerError.interrupted }
        if let error = request.error { throw error }
    }
    @discardableResult private func enqueue(_ operation: Operation, destructive: Bool) -> Request {
        operationID &+= 1
        let request = Request(id: operationID, operation: operation)
        pending = request
        if destructive { halt() }
        _ = state.beginStopping(); phase = .stopping
        if driver == nil {
            driver = Task { [weak self] in await self?.drive() }
        }
        return request
    }
    private func halt() {
        session?.owner.silence(); session?.worker.requestStop(); output.stop()
    }
    private func current(_ request: Request) -> Bool { request.id == operationID }
    private func check(_ request: Request) throws {
        guard current(request) else { throw PlaybackControllerError.interrupted }
        if cleanupBlocked {
            guard case .stop = request.operation else { throw PlaybackControllerError.cleanupTimeout }
        }
    }
    private func drive() async {
        while let request = pending {
            pending = nil; active = request
            do {
                try check(request)
                try await perform(request)
            } catch {
                request.error = error
                if current(request) {
                    if !(error is CancellationError), !(error as? PlaybackControllerError == .interrupted) {
                        lastError = session?.worker.snapshot().error ?? safeMessage(error)
                    }
                    halt()
                    if !cleanupBlocked {
                        do { try await disposeSession() }
                        catch { lastError = safeMessage(error) }
                    }
                    if current(request) {
                        if cleanupBlocked {
                            let ticket = state.beginStopping(); _ = state.fail(ticket); phase = state.phase
                        } else {
                            state.stop(); phase = .stopped; positionSeconds = 0; sourcePosition = 0
                            restoreFileMetadata()
                        }
                    }
                }
            }
            request.completed = true
            active = nil
        }
        driver = nil
    }
    private func perform(_ request: Request) async throws {
        switch request.operation {
        case .open(let url):
            try await disposeSession(); try check(request)
            input = nil; fileMetadata = nil; channelCount = 0; durationSeconds = 0
            sourcePosition = 0; positionSeconds = 0
            let opened = try makeSession(input: .file(url), rate: 48_000, ear: .left, seconds: 0, metadataOnly: true)
            session = opened
            let metadata = try await prepareWorker(opened, request: request, prefill: false)
            opened.metadata = metadata
            try check(request)
            try await disposeSession(); try check(request)
            input = .file(url); publish(metadata); confirmationActive = false
            if metadata.channelCount == 1, mode == .leftOnly || mode == .rightOnly {
                try set(mode: .mono, parameters: parameters, gainDB: gainDB)
            }
            lastError = nil
            state.stop(); phase = .stopped
        case .stop:
            try await disposeSession(); try check(request)
            sourcePosition = 0; positionSeconds = 0; cancellationWarning = false
            restoreFileMetadata()
            state.stop(); phase = .stopped
        case .pause:
            guard let session else { state.stop(); phase = .stopped; return }
            let ticket = state.beginStopping(); phase = .stopping
            session.owner.hold(); session.worker.requestPark(ticket: request.id); output.pausePlayback()
            let deadline = ContinuousClock.now + .seconds(2)
            while session.worker.snapshot().parkedTicket != request.id || session.worker.snapshot().metadata == nil {
                guard !session.worker.snapshot().finished else { throw PlaybackControllerError.sourceFailed }
                guard ContinuousClock.now < deadline else { throw PlaybackControllerError.cleanupTimeout }
                try await Task.sleep(for: .milliseconds(2)); try check(request)
            }
            try await output.waitUntilPaused(); try check(request)
            session.paused = true
            session.metadata = session.worker.snapshot().metadata
            displayToneMetadata(session)
            _ = state.finishStopping(ticket, paused: true); phase = state.phase
            poll()
        case .seek(let seconds, let restart):
            try await disposeSession(); try check(request)
            sourcePosition = seconds; positionSeconds = seconds
            if restart { try await start(request, input: input!, seconds: seconds) }
            else { state.stop(); phase = .stopped }
        case .tone:
            try await disposeSession(); try check(request)
            // The selected file remains available for a later explicit Play operation.
            try await start(request, input: .tone, seconds: 0)
        case .play:
            if let session, session.paused, !session.owner.stats.silenced {
                let snapshot = session.worker.snapshot()
                guard snapshot.error == nil, !session.owner.stats.faulted else { throw PlaybackControllerError.sourceFailed }
                let ticket = state.beginPreparation(); phase = .preparing
                session.worker.requestResume(ticket: request.id)
                let resumeDeadline = ContinuousClock.now + .seconds(2)
                while session.worker.snapshot().resumedTicket != request.id {
                    try check(request)
                    guard session.worker.snapshot().error == nil, !session.worker.snapshot().finished else {
                        throw PlaybackControllerError.sourceFailed
                    }
                    guard ContinuousClock.now < resumeDeadline else { throw PlaybackControllerError.cleanupTimeout }
                    try await Task.sleep(for: .milliseconds(2))
                }
                try check(request)
                if !session.outputPrepared {
                    let deadline = ContinuousClock.now + .seconds(2)
                    while !session.worker.snapshot().ready {
                        guard session.worker.snapshot().error == nil, !session.worker.snapshot().finished else {
                            throw PlaybackControllerError.sourceFailed
                        }
                        guard ContinuousClock.now < deadline else { throw PlaybackControllerError.cleanupTimeout }
                        try await Task.sleep(for: .milliseconds(2)); try check(request)
                    }
                    guard let metadata = session.worker.snapshot().metadata, let uid = session.uid,
                          selectedUID == uid, selectedEar == session.ear else { throw PlaybackControllerError.selectionRequired }
                    session.metadata = metadata
                    displayToneMetadata(session)
                    if session.worker.snapshot().producerDone && session.worker.snapshot().totalAccepted == 0 {
                        try await disposeSession(); try check(request)
                        state.stop(); phase = .stopped; restoreFileMetadata()
                        return
                    }
                    try await output.prepare(uid: uid, sampleRate: metadata.outputRate, renderOwner: session.owner)
                    session.outputPrepared = true
                    try check(request)
                }
                try output.resumePlayback(); try check(request)
                session.paused = false; resetProgress(session)
                _ = state.finishPreparation(ticket); _ = state.start(ticket); phase = state.phase
                lastError = nil; poll()
            } else {
                try await disposeSession(); try check(request)
                guard let input else { throw rejected(.sourceRequired) }
                try await start(request, input: input, seconds: sourcePosition)
            }
        }
    }
    private func prepareWorker(_ session: Session, request: Request, prefill: Bool) async throws -> PlaybackWorker.Metadata {
        let worker = session.worker
        session.preparationTask = Task { _ = try? await worker.prepare(prefill: prefill) }
        // Do not await an uncooperative file read from the sole control driver.
        // A superseding stop can now enter bounded disposal while this task is retained.
        while true {
            try check(request)
            let snapshot = worker.snapshot()
            guard snapshot.error == nil, !snapshot.finished else { throw PlaybackControllerError.sourceFailed }
            if (prefill ? snapshot.ready : snapshot.parked), let metadata = snapshot.metadata { return metadata }
            try await Task.sleep(for: .milliseconds(2))
        }
    }
    private func displayToneMetadata(_ session: Session) {
        if confirmationActive, let metadata = session.metadata {
            channelCount = metadata.channelCount; durationSeconds = metadata.durationSeconds
        }
    }

    private func makeSession(input: Input, rate: Double, ear: HearingEar, seconds: Double, metadataOnly: Bool = false) throws -> Session {
        let owner = try PlaybackRenderOwner(ear: ear)
        nextSessionID &+= 1
        let sourceRate: Double
        switch input { case .tone: sourceRate = 48_000; case .file: sourceRate = fileMetadata?.sourceRate ?? 48_000 }
        let frame: Int64
        if seconds == 0 { frame = 0 }
        else {
            guard let metadata = fileMetadata, seconds.isFinite, seconds >= 0,
                  seconds <= metadata.durationSeconds else { throw PlaybackControllerError.invalidSeek }
            if seconds == metadata.durationSeconds { frame = metadata.sourceFrameCount }
            else {
                let scaled = (seconds * sourceRate).rounded(.down)
                guard scaled.isFinite, scaled >= 0, scaled < Double(Int64.max) else {
                    throw PlaybackControllerError.invalidSeek
                }
                frame = min(Int64(scaled), metadata.sourceFrameCount)
            }
        }
        let pipelineFactory = pipelineFactory
        // Metadata inspection never starts output and must not inherit a stereo-only mode.
        let worker = PlaybackWorker(sessionID: nextSessionID, owner: owner, settings: metadataOnly ? .initial : settings, sourceFrame: frame) {
            switch input {
            case .file(let url): try pipelineFactory(url, rate)
            case .tone: try AudioFilePipeline(confirmationToneOutputRate: rate)
            }
        }
        return Session(id: nextSessionID, owner: owner, worker: worker, segmentStart: seconds,
                       uid: selectedUID, ear: ear, now: now())
    }
    private func start(_ request: Request, input: Input, seconds: Double) async throws {
        guard let uid = selectedUID, let ear = selectedEar else { throw rejected(.selectionRequired) }
        let matches = try devices().filter { $0.uid == uid }
        guard matches.count == 1, let device = matches.first, device.isSupportedForStageA else {
            throw DeviceOutputError.unavailable
        }
        if case .tone = input { confirmationActive = true } else { confirmationActive = false }
        let ticket = state.beginPreparation(); phase = .preparing
        let created = try makeSession(input: input, rate: device.sampleRate, ear: ear, seconds: seconds)
        session = created
        created.metadata = try await prepareWorker(created, request: request, prefill: true); try check(request)
        if case .tone = input, let metadata = created.metadata {
            channelCount = metadata.channelCount; durationSeconds = metadata.durationSeconds
        }
        let prepared = created.worker.snapshot()
        if prepared.producerDone && prepared.totalAccepted == 0 {
            try await disposeSession(); try check(request)
            state.stop(); phase = .stopped; positionSeconds = 0; sourcePosition = 0
            restoreFileMetadata()
            return
        }
        try await output.prepare(uid: uid, sampleRate: device.sampleRate, renderOwner: created.owner)
        created.outputPrepared = true
        try check(request)
        guard created.worker.snapshot().error == nil else { throw PlaybackControllerError.sourceFailed }
        try output.startPlayback(); try check(request)
        resetProgress(created)
        _ = state.finishPreparation(ticket); _ = state.start(ticket); phase = state.phase
        lastError = nil; poll()
    }
    private func disposeSession() async throws {
        guard let old = session else { return }
        old.owner.silence(); old.worker.requestStop(); output.stop()
        let deadline = ContinuousClock.now + .seconds(2)
        while !old.worker.completionConfirmed {
            guard ContinuousClock.now < deadline else { cleanupBlocked = true; throw PlaybackControllerError.cleanupTimeout }
            try await Task.sleep(for: .milliseconds(2))
        }
        await old.preparationTask?.value
        do { try await output.waitUntilStopped() }
        catch {
            // A newer destructive request may invalidate only the wait ticket; driver
            // remains the sole owner and may repeat the proof without touching a new graph.
            if error as? DeviceOutputError == .stale { try await output.waitUntilStopped() }
            else { cleanupBlocked = true; throw error }
        }
        if session === old { session = nil }
        cleanupBlocked = false
    }
    private func restoreFileMetadata() {
        confirmationActive = false
        channelCount = fileMetadata?.channelCount ?? 0
        durationSeconds = fileMetadata?.durationSeconds ?? 0
    }
    private func publish(_ metadata: PlaybackWorker.Metadata) {
        fileMetadata = metadata; channelCount = metadata.channelCount; durationSeconds = metadata.durationSeconds
    }
    private func resetProgress(_ session: Session) {
        let stats = session.owner.stats
        session.lastRendered = stats.rendered_frames; session.lastProgress = now()
        session.underrunTimes.removeAll(keepingCapacity: true); session.underrunBaseline = stats.underruns
        session.drainDeadline = nil
    }
    private func failAndStop(_ message: String) {
        lastError = message
        _ = enqueue(.stop, destructive: true)
    }
    private func rejected(_ error: PlaybackControllerError) -> PlaybackControllerError {
        lastError = error.localizedDescription
        return error
    }
    private func safeMessage(_ error: Error) -> String {
        if let known = error as? PlaybackControllerError { return known.localizedDescription }
        if let known = error as? DeviceOutputError { return known.localizedDescription }
        return PlaybackControllerError.sourceFailed.localizedDescription
    }

    struct Diagnostics {
        let sessionID: UInt64?
        let totalAccepted: UInt64
        let renderedFrames: UInt64
        let underruns: UInt64
        let queueHighWater: UInt32
        let pendingCount: Int
        let workerFinished: Bool
        let producerDone: Bool
        let callbackEntries: UInt64
        let callbackExits: UInt64
    }
    var diagnostics: Diagnostics {
        let worker = session?.worker.snapshot()
        let queue = session?.owner.stats
        let render = session.map { mo_render_context_read_stats($0.owner.context) }
        return Diagnostics(sessionID: session?.id, totalAccepted: worker?.totalAccepted ?? 0,
                           renderedFrames: queue?.rendered_frames ?? 0, underruns: queue?.underruns ?? 0,
                           queueHighWater: queue?.high_water_frames ?? 0, pendingCount: worker?.pendingCount ?? 0,
                           workerFinished: worker?.finished ?? true, producerDone: worker?.producerDone ?? false,
                           callbackEntries: render?.entries ?? 0, callbackExits: render?.exits ?? 0)
    }

    func pollForTesting() { poll() }
    private func poll() {
        guard let session, let metadata = session.metadata else { return }
        let snapshot = session.worker.snapshot()
        let stats = session.owner.stats
        if let error = snapshot.error {
            if phase != .stopping { failAndStop(error) }
            return
        }
        if stats.faulted || mo_render_context_read_stats(session.owner.context).faulted {
            if phase != .stopping { failAndStop(DeviceOutputError.invalidBuffer.localizedDescription) }
            return
        }
        guard phase == .running || phase == .paused else { return }
        cancellationWarning = snapshot.cancellationWarning
        let audioFrames = stats.rendered_frames > UInt64(metadata.latencyFrames)
            ? stats.rendered_frames - UInt64(metadata.latencyFrames) : 0
        positionSeconds = min(metadata.durationSeconds, session.segmentStart + Double(audioFrames) / metadata.outputRate)
        let time = now()
        if snapshot.producerDone && stats.rendered_frames == snapshot.totalAccepted {
            guard phase == .running else { return }
            session.owner.hold()
            if session.drainDeadline == nil { session.drainDeadline = time + max(0, output.drainDuration) }
            if time >= session.drainDeadline! { _ = enqueue(.stop, destructive: true) }
            return
        }
        guard phase == .running, !snapshot.producerDone else { return }
        if stats.rendered_frames != session.lastRendered {
            session.lastRendered = stats.rendered_frames; session.lastProgress = time
        }
        session.underrunTimes.removeAll { time - $0 >= 1 }
        let newUnderruns = min(3, stats.underruns &- session.underrunBaseline)
        session.underrunBaseline = stats.underruns
        for _ in 0..<newUnderruns {
            if session.underrunTimes.count == 3 { session.underrunTimes.removeFirst() }
            session.underrunTimes.append(time)
        }
        if session.underrunTimes.count >= 3 ||
            ((snapshot.totalAccepted > stats.rendered_frames || snapshot.pendingCount > 0) && time - session.lastProgress >= 0.5) {
            failAndStop("音声の供給または出力が進まないため停止しました。")
        }
    }
}
