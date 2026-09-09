import XCTest
@testable import MonoOtoCore

final class EncoderTests: XCTestCase {
    private let transitionSamples = 960

    func testCenterIsUnchanged() {
        let e = try! Encoder(parameters: .init(strength: 0.6, cutoffHz: 1500))
        e.setMode(.cue)
        for x in [Float(0), 0.25, -0.5, 1, -1] {
            XCTAssertEqual(e.process(left: x, right: x).mono, x, accuracy: 1e-6)
        }
    }

    func testZeroStrengthEqualsMono() {
        let e = try! Encoder(parameters: .init(strength: 0, cutoffHz: 1500))
        e.setMode(.cue)
        XCTAssertEqual(e.process(left: 0.8, right: -0.2).mono, 0.3, accuracy: 1e-6)
    }

    func testCueImpulseAndBlockSplitMatchIndependentReference() {
        let parameters = EncoderParameters(strength: 0.6, cutoffHz: 1500)
        for impulse in [(Float(1), Float(0)), (Float(0), Float(1))] {
            let e = settledEncoder(parameters: parameters, mode: .cue)
            var referenceState = 0.0
            for index in 0..<256 {
                let l: Float = index == 0 ? impulse.0 : 0
                let r: Float = index == 0 ? impulse.1 : 0
                let expected = reference(left: l, right: r, parameters: parameters, state: &referenceState)
                XCTAssertEqual(e.process(left: l, right: r).mono, expected, accuracy: 1e-6)
            }
        }

        let signal = (0..<257).map { i in
            (Float(sin(Double(i) * 0.17)) * 0.7, Float(cos(Double(i) * 0.11)) * 0.4)
        }
        let continuous = settledEncoder(parameters: parameters, mode: .cue)
        let split = settledEncoder(parameters: parameters, mode: .cue)
        let a = signal.map { continuous.process(left: $0.0, right: $0.1).mono }
        let first = signal[..<91].map { split.process(left: $0.0, right: $0.1).mono }
        let second = signal[91...].map { split.process(left: $0.0, right: $0.1).mono }
        XCTAssertEqual(a, first + second)
    }

    func testSwappingLeftAndRightReversesCueContribution() {
        let p = EncoderParameters(strength: 0.6, cutoffHz: 1500)
        let left = settledEncoder(parameters: p, mode: .cue)
        let right = settledEncoder(parameters: p, mode: .cue)
        for i in 0..<300 {
            let l = Float(sin(Double(i) * 0.2)) * 0.5
            let r = Float(cos(Double(i) * 0.07)) * 0.3
            let mid = l * 0.5 + r * 0.5
            XCTAssertEqual(left.process(left: l, right: r).mono - mid,
                           -(right.process(left: r, right: l).mono - mid), accuracy: 1e-6)
        }
    }

    func testAnalyticSteadyStateFrequencyResponse() {
        let p = EncoderParameters(strength: 0.6, cutoffHz: 1500)
        for frequency in [Float(100), 1500, 8000] {
            let e = settledEncoder(parameters: p, mode: .cue)
            var sumY2 = 0.0
            var sumX2 = 0.0
            for i in 0..<12000 {
                let x = Float(sin(2 * Double.pi * Double(frequency) * Double(i) / 48000))
                let y = e.process(left: x, right: -x).mono
                if i >= 4000 { sumY2 += Double(y * y); sumX2 += Double(x * x) }
            }
            let measured = sqrt(sumY2 / sumX2)
            let omega = 2 * Double.pi * Double(frequency) / 48000
            let c = exp(-2 * Double.pi * 1500 / 48000)
            let hpReal = 1 - (1 - c) * (1 - c * cos(omega)) / (1 + c * c - 2 * c * cos(omega))
            let hpImag = -(1 - c) * c * sin(omega) / (1 + c * c - 2 * c * cos(omega))
            let expected = 0.6 * hypot(hpReal, hpImag)
            XCTAssertEqual(measured, expected, accuracy: 2e-4)
        }
    }

    func testModesAndParametersRampForExactlyAtLeastTwentyMilliseconds() {
        let e = try! Encoder(parameters: .init(strength: 0, cutoffHz: 1500))
        e.setMode(.leftOnly)
        XCTAssertEqual(e.process(left: 1, right: 0).mono, 0.5 + 0.5 / 960, accuracy: 1e-6)
        for _ in 1..<958 { _ = e.process(left: 1, right: 0) }
        XCTAssertLessThan(e.process(left: 1, right: 0).mono, 1)
        XCTAssertEqual(e.process(left: 1, right: 0).mono, 1, accuracy: 1e-6)

        e.setMode(.rightOnly)
        for _ in 0..<480 { _ = e.process(left: 1, right: 0) }
        e.setMode(.leftOnly)
        let interrupted = e.process(left: 1, right: 0).mono
        XCTAssertGreaterThan(interrupted, 0.5)
        XCTAssertLessThan(interrupted, 1)
        for _ in 1..<960 { _ = e.process(left: 1, right: 0) }
        XCTAssertEqual(e.process(left: 1, right: 0).mono, 1, accuracy: 1e-6)

        let p = settledEncoder(parameters: .init(strength: 0, cutoffHz: 1500), mode: .cue)
        try! p.setParameters(.init(strength: 0.6, cutoffHz: 4000))
        let first = p.process(left: 1, right: -1).mono
        XCTAssertGreaterThan(first, 0)
        XCTAssertLessThan(first, 0.01)
        for i in 1..<960 {
            let x: Float = i.isMultiple(of: 2) ? 1 : -1
            _ = p.process(left: x, right: -x)
        }
        XCTAssertGreaterThan(abs(p.process(left: 1, right: -1).mono), 0.1)
    }

    func testParameterLimitsAndNonFiniteValuesFailClosed() {
        XCTAssertThrowsError(try Encoder(parameters: .init(strength: 99, cutoffHz: 4000)))
        XCTAssertThrowsError(try Encoder(parameters: .init(strength: 0.6, cutoffHz: 99_000)))
        XCTAssertThrowsError(try Encoder(parameters: .init(strength: .nan, cutoffHz: 1500)))

        let invalid = try! Encoder(parameters: .init(strength: 0.6, cutoffHz: 1500))
        invalid.setMode(.cue)
        XCTAssertEqual(invalid.process(left: .nan, right: 1), .init(mono: 0, cancellationWarning: false))
        XCTAssertTrue(invalid.isFaulted)
        invalid.reset()
        XCTAssertFalse(invalid.isFaulted)
        XCTAssertEqual(invalid.process(left: .greatestFiniteMagnitude, right: .greatestFiniteMagnitude).mono,
                       .greatestFiniteMagnitude)

        let retained = try! Encoder(parameters: .init(strength: 0, cutoffHz: 1500))
        retained.setMode(.cue)
        XCTAssertThrowsError(try retained.setParameters(.init(strength: 1, cutoffHz: 1500)))
        XCTAssertEqual(retained.process(left: 0.8, right: -0.2).mono, 0.3, accuracy: 1e-6)
    }

    func testResetClearsFilterTransitionAndWarningButPreservesSelectedSettings() {
        let e = try! Encoder(parameters: .init(strength: 0.6, cutoffHz: 1500))
        e.setMode(.cue)
        for _ in 0..<960 { _ = e.process(left: 0, right: 0) }
        _ = e.process(left: 1, right: -1)
        for _ in 0..<30000 { _ = e.process(left: 0.1, right: -0.1) }
        XCTAssertTrue(e.process(left: 0.1, right: -0.1).cancellationWarning)
        e.reset()
        var state = 0.0
        let expected = reference(left: 1, right: 0, parameters: .init(strength: 0.6, cutoffHz: 1500), state: &state)
        XCTAssertEqual(e.process(left: 1, right: 0).mono, expected, accuracy: 1e-6)
        XCTAssertFalse(e.process(left: 0, right: 0).cancellationWarning)
    }

    func testCancellationWarningUsesHundredMillisecondWindowAndFiveHundredMillisecondDuration() {
        let e = try! Encoder(parameters: .init(strength: 0.6, cutoffHz: 1500))
        for _ in 0..<28798 { XCTAssertFalse(e.process(left: 0.1, right: -0.1).cancellationWarning) }
        XCTAssertTrue(e.process(left: 0.1, right: -0.1).cancellationWarning)

        let belowRMS = try! Encoder(parameters: .init(strength: 0.6, cutoffHz: 1500))
        for _ in 0..<30000 { XCTAssertFalse(belowRMS.process(left: 0.0009, right: -0.0009).cancellationWarning) }

        let threshold = try! Encoder(parameters: .init(strength: 0.6, cutoffHz: 1500))
        let ratio: Float = 0.35
        for _ in 0..<30000 { XCTAssertFalse(threshold.process(left: 1 + ratio, right: ratio - 1).cancellationWarning) }
    }

    func testCancellationWindowRecoversAfterHugeFiniteSamplesLeaveWindow() {
        let e = try! Encoder(parameters: .init(strength: 0.6, cutoffHz: 1500))
        for _ in 0..<137 { _ = e.process(left: 0.1, right: 0.1) }
        _ = e.process(left: .greatestFiniteMagnitude, right: .greatestFiniteMagnitude)
        for _ in 0..<4662 { _ = e.process(left: 0.1, right: 0.1) }
        for _ in 0..<4800 { XCTAssertFalse(e.process(left: 0.1, right: -0.1).cancellationWarning) }
        var warning = false
        for _ in 0..<24000 { warning = e.process(left: 0.1, right: -0.1).cancellationWarning }
        XCTAssertTrue(warning)
    }

    func testQuantizedCancellationThresholdsClearAndRearmForFullDuration() {
        assertWarningForQuantizedInput(nominalRatio: 0.0999, rms: 0.1, ratioBelowThreshold: true, rmsAboveThreshold: true)
        // Float channel quantization places this nominal 0.1 ratio below the strict threshold.
        assertWarningForQuantizedInput(nominalRatio: 0.1, rms: 0.1, ratioBelowThreshold: true, rmsAboveThreshold: true)
        assertWarningForQuantizedInput(nominalRatio: 0.1001, rms: 0.1, ratioBelowThreshold: false, rmsAboveThreshold: true)
        assertWarningForQuantizedInput(nominalRatio: 0, rms: Float(0.001).nextDown, ratioBelowThreshold: true, rmsAboveThreshold: false)
        // Float(0.001) is strictly greater than the Double threshold 0.001.
        assertWarningForQuantizedInput(nominalRatio: 0, rms: Float(0.001), ratioBelowThreshold: true, rmsAboveThreshold: true)
        assertWarningForQuantizedInput(nominalRatio: 0, rms: Float(0.001).nextUp, ratioBelowThreshold: true, rmsAboveThreshold: true)

        let e = try! Encoder(parameters: .init(strength: 0.6, cutoffHz: 1500))
        for _ in 0..<28799 { _ = e.process(left: 0.1, right: -0.1) }
        XCTAssertTrue(e.process(left: 0.1, right: -0.1).cancellationWarning)
        _ = e.process(left: .greatestFiniteMagnitude, right: .greatestFiniteMagnitude)
        for _ in 0..<4799 { XCTAssertFalse(e.process(left: 0.1, right: -0.1).cancellationWarning) }
        XCTAssertFalse(e.process(left: 0.1, right: -0.1).cancellationWarning)
        for _ in 0..<23998 { XCTAssertFalse(e.process(left: 0.1, right: -0.1).cancellationWarning) }
        XCTAssertTrue(e.process(left: 0.1, right: -0.1).cancellationWarning)
    }

    func testParameterAndCoefficientTransitionMatchesReferenceAndCanBeInterrupted() {
        let e = settledEncoder(parameters: .init(strength: 0.1, cutoffHz: 800), mode: .cue)
        try! e.setParameters(.init(strength: 0.5, cutoffHz: 4000))
        var strength = 0.1
        var cutoff = 800.0
        var strengthStep = (0.5 - strength) / 960
        var cutoffStep = (4000.0 - cutoff) / 960
        var remaining = 960
        var filterState = 0.0

        for index in 0..<1293 {
            if index == 333 {
                try! e.setParameters(.init(strength: 0.2, cutoffHz: 2000))
                strengthStep = (0.2 - strength) / 960
                cutoffStep = (2000.0 - cutoff) / 960
                remaining = 960
            }
            if remaining > 0 {
                strength += strengthStep
                cutoff += cutoffStep
                remaining -= 1
                if remaining == 0 {
                    strength = 0.2
                    cutoff = 2000
                }
            }
            let left = Float(sin(Double(index) * 0.173)) * 0.7
            let right = Float(cos(Double(index) * 0.097)) * 0.4
            let expected = transitionReference(left: left, right: right, strength: strength,
                                               cutoffHz: cutoff, state: &filterState)
            XCTAssertEqual(e.process(left: left, right: right).mono, expected, accuracy: 1e-6)
        }
    }

    func testCachedCoefficientMatchesPerSampleFormulaAcrossStableRampsRetargetAndReset() throws {
        var target = EncoderParameters(strength: 0.125, cutoffHz: 800)
        let encoder = settledEncoder(parameters: target, mode: .cue)
        var strength = Double(target.strength)
        var cutoff = Double(target.cutoffHz)
        var strengthStep = 0.0
        var cutoffStep = 0.0
        var remaining = 0
        var state = 0.0

        for index in 0..<6500 {
            let next: EncoderParameters?
            switch index {
            case 100: next = .init(strength: 0.5, cutoffHz: 4000)
            case 433: next = .init(strength: 0.25, cutoffHz: 2000) // Retarget an unfinished ramp.
            case 2500: next = .init(strength: 0.5, cutoffHz: 2000) // Strength-only ramp.
            case 3600: next = target // Reapplying identical parameters.
            case 4700: next = .init(strength: 0.125, cutoffHz: 800)
            default: next = nil
            }
            if let next {
                target = next
                try encoder.setParameters(next)
                strengthStep = (Double(next.strength) - strength) / 960
                cutoffStep = (Double(next.cutoffHz) - cutoff) / 960
                remaining = 960
            }
            if index == 4900 { // Reset snaps an unfinished ramp to its selected target.
                encoder.reset()
                strength = Double(target.strength)
                cutoff = Double(target.cutoffHz)
                remaining = 0
                state = 0
            }
            if remaining > 0 {
                strength += strengthStep
                cutoff += cutoffStep
                remaining -= 1
                if remaining == 0 {
                    strength = Double(target.strength)
                    cutoff = Double(target.cutoffHz)
                }
            }
            let left = Float(sin(Double(index) * 0.173)) * 0.7
            let right = Float(cos(Double(index) * 0.097)) * 0.4
            let expected = transitionReference(left: left, right: right, strength: strength,
                                               cutoffHz: cutoff, state: &state)
            XCTAssertEqual(encoder.process(left: left, right: right).mono, expected, "sample \(index)")
        }
    }

    func testKnownLimitationAntiPhaseAndNarrowBandCanLoseInformation() {
        let mono = try! Encoder(parameters: .init(strength: 0.6, cutoffHz: 1500))
        XCTAssertEqual(mono.process(left: 0.5, right: -0.5).mono, 0, accuracy: 1e-6)

        let cue = settledEncoder(parameters: .init(strength: 0.6, cutoffHz: 1500), mode: .cue)
        var peak: Float = 0
        for i in 0..<96000 {
            let x = Float(sin(2 * Double.pi * 0.1 * Double(i) / 48000))
            let y = cue.process(left: x, right: -x).mono
            if i > 48000 { peak = max(peak, abs(y)) }
        }
        XCTAssertLessThan(peak, 0.0001)
    }

    private func settledEncoder(parameters: EncoderParameters, mode: ListeningMode) -> Encoder {
        let e = try! Encoder(parameters: parameters)
        e.setMode(mode)
        for _ in 0..<transitionSamples { _ = e.process(left: 0, right: 0) }
        return e
    }

    private func reference(left: Float, right: Float, parameters: EncoderParameters, state: inout Double) -> Float {
        let mid = Double(left) * 0.5 + Double(right) * 0.5
        let side = Double(left) * 0.5 - Double(right) * 0.5
        let c = exp(-2 * Double.pi * Double(parameters.cutoffHz) / 48000)
        state = (1 - c) * side + c * state
        return Float(mid + Double(parameters.strength) * (side - state))
    }

    private func transitionReference(left: Float, right: Float, strength: Double,
                                     cutoffHz: Double, state: inout Double) -> Float {
        let mid = Double(left) * 0.5 + Double(right) * 0.5
        let side = Double(left) * 0.5 - Double(right) * 0.5
        let c = exp(-2 * Double.pi * cutoffHz / 48000)
        state = (1 - c) * side + c * state
        return Float(mid + strength * (side - state))
    }

    private func assertWarningForQuantizedInput(nominalRatio: Double, rms: Float,
                                               ratioBelowThreshold: Bool, rmsAboveThreshold: Bool,
                                               file: StaticString = #filePath, line: UInt = #line) {
        let e = try! Encoder(parameters: .init(strength: 0.6, cutoffHz: 1500))
        let inputEnergy = Double(rms) * Double(rms)
        let mid = sqrt(nominalRatio * (inputEnergy + 1e-12))
        let side = sqrt(max(0, inputEnergy - mid * mid))
        let left = Float(mid + side)
        let right = Float(mid - side)
        let actualMid = Double(left) * 0.5 + Double(right) * 0.5
        let actualInput = (Double(left) * Double(left) + Double(right) * Double(right)) * 0.5
        let actualRatio = actualMid * actualMid / (actualInput + 1e-12)
        XCTAssertEqual(actualRatio < 0.1, ratioBelowThreshold, file: file, line: line)
        XCTAssertEqual(actualInput.squareRoot() > 0.001, rmsAboveThreshold, file: file, line: line)
        var warning = false
        for _ in 0..<28799 { warning = e.process(left: left, right: right).cancellationWarning }
        XCTAssertEqual(warning, ratioBelowThreshold && rmsAboveThreshold, file: file, line: line)
    }
}
