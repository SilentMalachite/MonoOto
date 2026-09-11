public enum PlaybackPhase: Equatable, Sendable {
    case stopped
    case preparing
    case running
    case paused
    case stopping
    case error
}

public struct PlaybackTicket: Equatable, Sendable {
    public let generation: UInt64

    init(generation: UInt64) {
        self.generation = generation
    }
}

@MainActor
public final class PlaybackState {
    public private(set) var phase: PlaybackPhase = .stopped

    private var generation: UInt64 = 0
    private var preparationIsReady = false

    public init() {}

    public func beginPreparation() -> PlaybackTicket {
        advanceGeneration()
        preparationIsReady = false
        phase = .preparing
        return PlaybackTicket(generation: generation)
    }

    @discardableResult
    public func finishPreparation(_ ticket: PlaybackTicket) -> Bool {
        guard ticket.generation == generation, phase == .preparing else {
            return false
        }
        preparationIsReady = true
        return true
    }

    @discardableResult
    public func start(_ ticket: PlaybackTicket) -> Bool {
        guard ticket.generation == generation,
              phase == .preparing,
              preparationIsReady else {
            return false
        }
        phase = .running
        return true
    }

    public func beginStopping() -> PlaybackTicket {
        invalidateCurrentTicket()
        phase = .stopping
        return PlaybackTicket(generation: generation)
    }

    @discardableResult
    public func finishStopping(_ ticket: PlaybackTicket, paused: Bool = false) -> Bool {
        guard ticket.generation == generation, phase == .stopping else { return false }
        phase = paused ? .paused : .stopped
        return true
    }

    public func stop() {
        invalidateCurrentTicket()
        phase = .stopped
    }

    public func pause() {
        invalidateCurrentTicket()
        phase = .paused
    }

    @discardableResult
    public func fail(_ ticket: PlaybackTicket) -> Bool {
        guard ticket.generation == generation else { return false }
        invalidateCurrentTicket()
        phase = .error
        return true
    }

    private func invalidateCurrentTicket() {
        advanceGeneration()
        preparationIsReady = false
    }

    private func advanceGeneration() {
        generation &+= 1
    }
}
