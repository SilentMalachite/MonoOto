import Foundation

public enum OutputGuardError: Error, Equatable, Sendable {
    case unsupportedSampleRate
}

public final class OutputGuard {
    public private(set) var faulted = false
    public let latencyFrames: Int

    private static let ceiling = Float(pow(10.0, -3.0 / 20.0))
    private let releaseCoefficient: Double
    private var delay: [Float]
    private var delayIndex = 0
    private var sampleIndex = 0
    private var gain = 1.0

    private var peakValues: [Float]
    private var peakIndices: [Int]
    private var peakHead = 0
    private var peakCount = 0

    public init(sampleRate: Double) throws {
        guard sampleRate == 44_100 || sampleRate == 48_000 else {
            throw OutputGuardError.unsupportedSampleRate
        }
        latencyFrames = Int(ceil(sampleRate * 0.005))
        releaseCoefficient = exp(-1.0 / (sampleRate * 0.1))
        delay = Array(repeating: 0, count: latencyFrames)
        peakValues = Array(repeating: 0, count: latencyFrames + 1)
        peakIndices = Array(repeating: 0, count: latencyFrames + 1)
    }

    public func process(_ x: Float) -> Float {
        guard !faulted else { return 0 }
        guard x.isFinite else {
            clearState()
            faulted = true
            return 0
        }

        let outgoing = delay[delayIndex]
        delay[delayIndex] = x
        delayIndex = (delayIndex + 1) % latencyFrames

        appendPeak(abs(x), at: sampleIndex)
        let peak = peakValues[peakHead]
        let required = peak > 0 ? min(1.0, Double(Self.ceiling) / Double(peak)) : 1.0
        gain = required < gain
            ? required
            : releaseCoefficient * gain + (1 - releaseCoefficient) * required

        let candidate = Double(outgoing) * gain
        let ceiling = Double(Self.ceiling)
        guard candidate.isFinite else {
            clearState()
            faulted = true
            return 0
        }
        let output = Float(min(ceiling, max(-ceiling, candidate)))

        // Retain x[n - latencyFrames] through output calculation, then expire it.
        // The next append therefore needs at most latencyFrames + 1 queue slots.
        removeExpiredPeaks(through: sampleIndex - latencyFrames)
        sampleIndex += 1
        return output
    }

    public func reset() {
        clearState()
        faulted = false
    }

    private func clearState() {
        for index in delay.indices { delay[index] = 0 }
        delayIndex = 0
        sampleIndex = 0
        gain = 1
        peakHead = 0
        peakCount = 0
    }

    private func appendPeak(_ value: Float, at index: Int) {
        while peakCount > 0 {
            let last = (peakHead + peakCount - 1) % peakValues.count
            guard peakValues[last] > value else {
                peakCount -= 1
                continue
            }
            break
        }
        let insertion = (peakHead + peakCount) % peakValues.count
        peakValues[insertion] = value
        peakIndices[insertion] = index
        peakCount += 1
    }

    private func removeExpiredPeaks(through index: Int) {
        while peakCount > 0, peakIndices[peakHead] <= index {
            peakHead = (peakHead + 1) % peakValues.count
            peakCount -= 1
        }
    }
}
