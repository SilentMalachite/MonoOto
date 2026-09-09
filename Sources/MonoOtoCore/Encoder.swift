import Foundation

public enum ListeningMode: String, Codable, Sendable {
    case mono, cue, leftOnly, rightOnly
}

public enum HearingEar: String, Codable, Sendable {
    case left, right
}

public struct EncoderParameters: Equatable, Sendable {
    public var strength: Float
    public var cutoffHz: Float

    public init(strength: Float, cutoffHz: Float) {
        self.strength = strength
        self.cutoffHz = cutoffHz
    }
}

public struct EncodedSample: Equatable, Sendable {
    public let mono: Float
    public let cancellationWarning: Bool

    public init(mono: Float, cancellationWarning: Bool) {
        self.mono = mono
        self.cancellationWarning = cancellationWarning
    }
}

public enum EncoderError: Error, Equatable, Sendable {
    case invalidStrength
    case invalidCutoffHz
}

public final class Encoder {
    public static let sampleRate: Float = 48_000
    public private(set) var isFaulted = false

    private static let transitionLength = 960
    private static let windowLength = 4_800
    private static let warningDuration = 24_000
    private static let energyLeafCount = 8_192
    private var targetParameters: EncoderParameters
    private var strength: Double
    private var cutoffHz: Double
    private var lowPassCoefficient: Double
    private var strengthStep = 0.0
    private var cutoffStep = 0.0
    private var parameterSamplesRemaining = 0
    private var targetMode: ListeningMode = .mono
    private var weights = ModeWeights.mono
    private var weightSteps = ModeWeights.zero
    private var modeSamplesRemaining = 0
    private var lowPassState = 0.0
    private var leftEnergyTree = Array(repeating: 0.0, count: energyLeafCount * 2)
    private var rightEnergyTree = Array(repeating: 0.0, count: energyLeafCount * 2)
    private var midEnergyTree = Array(repeating: 0.0, count: energyLeafCount * 2)
    private var energyIndex = 0
    private var energyCount = 0
    private var cancellationSamples = 0

    public init(parameters: EncoderParameters) throws {
        try Self.validate(parameters)
        targetParameters = parameters
        strength = Double(parameters.strength)
        cutoffHz = Double(parameters.cutoffHz)
        lowPassCoefficient = Self.coefficient(cutoffHz: Double(parameters.cutoffHz))
    }

    public func setParameters(_ parameters: EncoderParameters) throws {
        try Self.validate(parameters)
        targetParameters = parameters
        strengthStep = (Double(parameters.strength) - strength) / Double(Self.transitionLength)
        cutoffStep = (Double(parameters.cutoffHz) - cutoffHz) / Double(Self.transitionLength)
        parameterSamplesRemaining = Self.transitionLength
    }

    public func setMode(_ mode: ListeningMode) {
        targetMode = mode
        let target = ModeWeights(mode)
        weightSteps = (target - weights) / Double(Self.transitionLength)
        modeSamplesRemaining = Self.transitionLength
    }

    public func reset() {
        isFaulted = false
        strength = Double(targetParameters.strength)
        cutoffHz = Double(targetParameters.cutoffHz)
        lowPassCoefficient = Self.coefficient(cutoffHz: cutoffHz)
        strengthStep = 0
        cutoffStep = 0
        parameterSamplesRemaining = 0
        weights = ModeWeights(targetMode)
        weightSteps = .zero
        modeSamplesRemaining = 0
        lowPassState = 0
        for index in leftEnergyTree.indices {
            leftEnergyTree[index] = 0
            rightEnergyTree[index] = 0
            midEnergyTree[index] = 0
        }
        energyIndex = 0
        energyCount = 0
        cancellationSamples = 0
    }

    public func process(left: Float, right: Float) -> EncodedSample {
        guard !isFaulted, left.isFinite, right.isFinite else {
            isFaulted = true
            return .init(mono: 0, cancellationWarning: false)
        }
        advanceTransitions()
        let l = Double(left)
        let r = Double(right)
        let mid = l * 0.5 + r * 0.5
        let side = l * 0.5 - r * 0.5
        let c = lowPassCoefficient
        lowPassState = (1 - c) * side + c * lowPassState
        let cue = mid + strength * (side - lowPassState)
        let output = weights.mono * mid + weights.cue * cue + weights.left * l + weights.right * r
        guard output.isFinite else {
            isFaulted = true
            return .init(mono: 0, cancellationWarning: false)
        }
        let warning = updateCancellation(left: l, right: r, mid: mid)
        let limit = Double(Float.greatestFiniteMagnitude)
        return .init(mono: Float(min(max(output, -limit), limit)), cancellationWarning: warning)
    }

    private static func validate(_ parameters: EncoderParameters) throws {
        guard parameters.strength.isFinite, (0...0.6).contains(parameters.strength) else {
            throw EncoderError.invalidStrength
        }
        guard parameters.cutoffHz.isFinite, (800...4_000).contains(parameters.cutoffHz) else {
            throw EncoderError.invalidCutoffHz
        }
    }

    private static func coefficient(cutoffHz: Double) -> Double {
        exp(-2 * Double.pi * cutoffHz / Double(Self.sampleRate))
    }

    private func advanceTransitions() {
        if parameterSamplesRemaining > 0 {
            let previousCutoff = cutoffHz
            strength += strengthStep
            cutoffHz += cutoffStep
            parameterSamplesRemaining -= 1
            if parameterSamplesRemaining == 0 {
                strength = Double(targetParameters.strength)
                cutoffHz = Double(targetParameters.cutoffHz)
            }
            // Preserve per-sample cutoff smoothing while avoiding exp for a stable cutoff.
            if cutoffHz != previousCutoff {
                lowPassCoefficient = Self.coefficient(cutoffHz: cutoffHz)
            }
        }
        if modeSamplesRemaining > 0 {
            weights = weights + weightSteps
            modeSamplesRemaining -= 1
            if modeSamplesRemaining == 0 { weights = ModeWeights(targetMode) }
        }
    }

    private func updateCancellation(left: Double, right: Double, mid: Double) -> Bool {
        let l2 = left * left
        let r2 = right * right
        let m2 = mid * mid
        updateEnergyTrees(left: l2, right: r2, mid: m2, at: energyIndex)
        energyIndex = (energyIndex + 1) % Self.windowLength
        energyCount = min(energyCount + 1, Self.windowLength)
        guard energyCount == Self.windowLength else {
            cancellationSamples = 0
            return false
        }
        let count = Double(Self.windowLength)
        let inputEnergy = (leftEnergyTree[1] + rightEnergyTree[1]) / (2 * count)
        let ratio = (midEnergyTree[1] / count) / (inputEnergy + 1e-12)
        if inputEnergy.squareRoot() > 0.001, ratio < 0.1 {
            cancellationSamples = min(cancellationSamples + 1, Self.warningDuration)
        } else {
            cancellationSamples = 0
        }
        return cancellationSamples >= Self.warningDuration
    }

    private func updateEnergyTrees(left: Double, right: Double, mid: Double, at index: Int) {
        var node = Self.energyLeafCount + index
        leftEnergyTree[node] = left
        rightEnergyTree[node] = right
        midEnergyTree[node] = mid
        node /= 2
        while node > 0 {
            let firstChild = node * 2
            leftEnergyTree[node] = leftEnergyTree[firstChild] + leftEnergyTree[firstChild + 1]
            rightEnergyTree[node] = rightEnergyTree[firstChild] + rightEnergyTree[firstChild + 1]
            midEnergyTree[node] = midEnergyTree[firstChild] + midEnergyTree[firstChild + 1]
            node /= 2
        }
    }
}

private struct ModeWeights {
    var mono: Double
    var cue: Double
    var left: Double
    var right: Double
    static let zero = Self(mono: 0, cue: 0, left: 0, right: 0)
    static let mono = Self(mono: 1, cue: 0, left: 0, right: 0)

    init(_ mode: ListeningMode) {
        self = .zero
        switch mode {
        case .mono: mono = 1
        case .cue: cue = 1
        case .leftOnly: left = 1
        case .rightOnly: right = 1
        }
    }

    init(mono: Double, cue: Double, left: Double, right: Double) {
        self.mono = mono; self.cue = cue; self.left = left; self.right = right
    }

    static func + (lhs: Self, rhs: Self) -> Self {
        Self(mono: lhs.mono + rhs.mono, cue: lhs.cue + rhs.cue,
             left: lhs.left + rhs.left, right: lhs.right + rhs.right)
    }

    static func - (lhs: Self, rhs: Self) -> Self {
        Self(mono: lhs.mono - rhs.mono, cue: lhs.cue - rhs.cue,
             left: lhs.left - rhs.left, right: lhs.right - rhs.right)
    }

    static func / (lhs: Self, rhs: Double) -> Self {
        Self(mono: lhs.mono / rhs, cue: lhs.cue / rhs,
             left: lhs.left / rhs, right: lhs.right / rhs)
    }
}
