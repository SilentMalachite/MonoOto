import XCTest
@testable import MonoOtoCore

final class OutputGuardTests: XCTestCase {
    private let ceiling = Float(pow(10.0, -3.0 / 20.0))

    func testSupportedRatesDelayByExactlyFiveMilliseconds() throws {
        for (rate, frames) in [(44_100.0, 221), (48_000.0, 240)] {
            let guarder = try OutputGuard(sampleRate: rate)
            XCTAssertEqual(guarder.latencyFrames, frames)
            XCTAssertEqual(guarder.process(0.25), 0)
            for _ in 1..<frames { XCTAssertEqual(guarder.process(0), 0) }
            XCTAssertEqual(guarder.process(0), 0.25, accuracy: 1e-7)
        }
    }

    func testUnsupportedAndNonFiniteSampleRatesThrow() {
        for rate in [0.0, 44_099.0, 96_000.0, .nan, .infinity] {
            XCTAssertThrowsError(try OutputGuard(sampleRate: rate))
        }
    }

    func testPositiveAndNegativeOversAreLimitedAtBothRates() throws {
        for rate in [44_100.0, 48_000.0] {
            for input: Float in [4, -4] {
                let guarder = try OutputGuard(sampleRate: rate)
                _ = guarder.process(input)
                for _ in 0..<guarder.latencyFrames - 1 { _ = guarder.process(0) }
                XCTAssertEqual(guarder.process(0), input.sign == .minus ? -ceiling : ceiling,
                               accuracy: 2e-6)
            }
        }
    }

    func testOutgoingImpulseRemainsInPeakWindowUntilItIsLimited() throws {
        for rate in [44_100.0, 48_000.0] {
            for sign: Float in [-1, 1] {
                let guarder = try OutputGuard(sampleRate: rate)
                _ = guarder.process(sign * 4)
                _ = guarder.process(sign * 0.5)
                for _ in 0..<guarder.latencyFrames - 2 { _ = guarder.process(0) }
                XCTAssertEqual(guarder.process(0), sign * ceiling, accuracy: 2e-6)
                let release = exp(-1.0 / (rate * 0.1))
                let expectedGain = release * Double(ceiling / 4) + (1 - release)
                // The following quiet sample reveals early or late release even if the
                // preceding impulse was capped by the final hard ceiling.
                XCTAssertEqual(guarder.process(0), Float(Double(sign * 0.5) * expectedGain),
                               accuracy: 1e-7)
            }
        }
    }

    func testDescendingPeaksFillQueueAndMatchUnclippedWindowReference() throws {
        for rate in [44_100.0, 48_000.0] {
            let guarder = try OutputGuard(sampleRate: rate)
            // Strictly descending peaks fill every queue slot and keep wrapping it.
            let count = guarder.latencyFrames * 4
            let input = (0..<count).map { index -> Float in
                let magnitude = Float(4 - 3.5 * Double(index) / Double(count - 1))
                return index.isMultiple(of: 2) ? magnitude : -magnitude
            }
            let actual = (input + Array(repeating: 0, count: guarder.latencyFrames))
                .map(guarder.process)
            let expected = slowReference(input: input, sampleRate: rate,
                                         latencyFrames: guarder.latencyFrames)
            for (index, values) in zip(actual, expected).enumerated() {
                XCTAssertEqual(values.0, values.1, accuracy: 1e-7,
                               "rate=\(rate), frame=\(index)")
            }
        }
    }

    func testMonotonicPeakQueueMatchesIndependentWindowScanAcrossWraps() throws {
        let rate = 44_100.0
        let guarder = try OutputGuard(sampleRate: rate)
        let count = guarder.latencyFrames * 4 + 37
        let input = (0..<count).map { index -> Float in
            if index == 3 || index == guarder.latencyFrames + 7 || index == guarder.latencyFrames * 3 + 2 {
                return index.isMultiple(of: 2) ? 3.5 : -4
            }
            return Float(index % 29 - 14) / 25
        }
        let actual = (input + Array(repeating: 0, count: guarder.latencyFrames)).map(guarder.process)
        let expected = slowReference(input: input, sampleRate: rate, latencyFrames: guarder.latencyFrames)
        XCTAssertEqual(actual.count, expected.count)
        for (value, reference) in zip(actual, expected) {
            XCTAssertEqual(value, reference, accuracy: 2e-6)
        }
    }

    func testSilenceAndOrdinarySignalAreNotAlteredApartFromDelay() throws {
        for rate in [44_100.0, 48_000.0] {
            let guarder = try OutputGuard(sampleRate: rate)
            let signal: [Float] = [0, 0.1, -0.3, 0.5, -0.6, 0.2]
            let output = (signal + Array(repeating: 0, count: guarder.latencyFrames)).map(guarder.process)
            XCTAssertEqual(Array(output.prefix(guarder.latencyFrames)),
                           Array(repeating: 0, count: guarder.latencyFrames))
            for (actual, expected) in zip(output.dropFirst(guarder.latencyFrames), signal) {
                XCTAssertEqual(actual, expected, accuracy: 1e-7)
            }
            XCTAssertTrue(output.allSatisfy(\.isFinite))
        }
    }

    func testTailFlushEmitsDelayedSamplesAndThenSilence() throws {
        for rate in [44_100.0, 48_000.0] {
            let guarder = try OutputGuard(sampleRate: rate)
            _ = guarder.process(0.4)
            for _ in 0..<guarder.latencyFrames - 1 { XCTAssertEqual(guarder.process(0), 0) }
            XCTAssertEqual(guarder.process(0), 0.4, accuracy: 1e-7)
            for _ in 0..<guarder.latencyFrames { XCTAssertEqual(guarder.process(0), 0) }
        }
    }

    func testInvalidInputLatchesSilenceAndClearsDelayedAudio() throws {
        for rate in [44_100.0, 48_000.0] {
            for invalid: Float in [.nan, .infinity, -.infinity] {
                let guarder = try OutputGuard(sampleRate: rate)
                _ = guarder.process(0.5)
                XCTAssertEqual(guarder.process(invalid), 0)
                XCTAssertTrue(guarder.faulted)
                for _ in 0..<guarder.latencyFrames + 1 { XCTAssertEqual(guarder.process(0.5), 0) }
                guarder.reset()
                XCTAssertFalse(guarder.faulted)
                for _ in 0..<guarder.latencyFrames { XCTAssertEqual(guarder.process(0), 0) }
            }
        }
    }

    func testExtremeFiniteValuesRemainFiniteAndBounded() throws {
        for rate in [44_100.0, 48_000.0] {
            let guarder = try OutputGuard(sampleRate: rate)
            for input: Float in [.greatestFiniteMagnitude, -.greatestFiniteMagnitude] {
                _ = guarder.process(input)
                for _ in 0..<guarder.latencyFrames - 1 { _ = guarder.process(0) }
                let output = guarder.process(0)
                XCTAssertTrue(output.isFinite)
                XCTAssertLessThanOrEqual(abs(output), ceiling)
            }
        }
    }

    func testGainReleaseUsesHundredMillisecondTimeConstant() throws {
        let rate = 48_000.0
        let guarder = try OutputGuard(sampleRate: rate)
        _ = guarder.process(4)
        for _ in 0..<guarder.latencyFrames { _ = guarder.process(0) }
        let limitedGain = Double(ceiling / 4)
        let releaseFrames = Int(rate * 0.1)
        for _ in 0..<(releaseFrames - guarder.latencyFrames - 1) { _ = guarder.process(0) }
        for _ in 0..<guarder.latencyFrames { _ = guarder.process(0.5) }
        let actual = Double(guarder.process(0.5) / 0.5)
        let expected = 1 - (1 - limitedGain) * exp(-1)
        XCTAssertEqual(actual, expected, accuracy: 0.002)
    }

    func testResetClearsDelayAndLimiterGain() throws {
        for rate in [44_100.0, 48_000.0] {
            let guarder = try OutputGuard(sampleRate: rate)
            _ = guarder.process(4)
            guarder.reset()
            for _ in 0..<guarder.latencyFrames { XCTAssertEqual(guarder.process(0.5), 0) }
            XCTAssertEqual(guarder.process(0.5), 0.5, accuracy: 1e-7)
        }
    }

    private func slowReference(input: [Float], sampleRate: Double, latencyFrames: Int) -> [Float] {
        let padded = input + Array(repeating: 0, count: latencyFrames)
        let release = exp(-1.0 / (sampleRate * 0.1))
        var gain = 1.0
        return padded.indices.map { index in
            let first = max(0, index - latencyFrames)
            let peak = padded[first...index].lazy.map { abs($0) }.max() ?? 0
            let required = peak > 0 ? min(1.0, Double(ceiling) / Double(peak)) : 1.0
            gain = required < gain ? required : release * gain + (1 - release) * required
            let delayed = index >= latencyFrames ? padded[index - latencyFrames] : 0
            // Do not clamp the reference: the peak window itself must control gain.
            return Float(Double(delayed) * gain)
        }
    }
}
