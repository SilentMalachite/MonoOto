import XCTest
import MonoOtoRealtime
import MonoOtoRealtimeTestSupport

final class FrameQueueTests: XCTestCase {
    func testRejectsInvalidConfiguration() {
        for capacity: UInt32 in [0, 3, 4097] { XCTAssertNil(mo_queue_create(capacity, 0)) }
        XCTAssertNil(mo_queue_create(8, 2))
    }
    func testCreatesValidCapacities() throws {
        for capacity: UInt32 in [1, 2, 4096] {
            let q = try XCTUnwrap(mo_queue_create(capacity, 0))
            XCTAssertFalse(mo_queue_read_stats(q).faulted)
            mo_queue_destroy(q)
        }
    }
    func testZeroCountAndNullQueue() {
        XCTAssertEqual(mo_queue_push(nil, nil, 0), 0)
        XCTAssertEqual(mo_queue_render(nil, MOFloatBuffer(), MOFloatBuffer(), 0), MO_RENDER_OK)
        XCTAssertTrue(mo_queue_read_stats(nil).faulted)
        mo_queue_destroy(nil)
        mo_queue_silence(nil)
    }
    func testEmptyQueueClearsOnlyRequestedFrames() throws {
        let q = try XCTUnwrap(mo_queue_create(2, 1)); defer { mo_queue_destroy(q) }
        let result = render(q, count: 3)
        XCTAssertEqual(result.0, MO_RENDER_UNDERRUN)
        XCTAssertEqual(result.1, [0, 0, 0, 9])
        XCTAssertEqual(result.2, [0, 0, 0, 9])
        XCTAssertEqual(mo_queue_read_stats(q).underruns, 1)
    }
    func testBackpressurePreservesOrder() throws {
        let q = try XCTUnwrap(mo_queue_create(4, 1)); defer { mo_queue_destroy(q) }
        XCTAssertEqual(push(q, [0.1, 0.2, 0.3, 0.4, 0.5]), 4)
        XCTAssertEqual(push(q, [0.5]), 0)
        XCTAssertEqual(render(q, count: 3).2, [0.1, 0.2, 0.3, 9])
        XCTAssertEqual(push(q, [0.5, 0.6]), 2)
        let result = render(q, count: 4)
        XCTAssertEqual(result.0, MO_RENDER_UNDERRUN)
        XCTAssertEqual(result.1, [0, 0, 0, 0, 9])
        XCTAssertEqual(result.2, [0.4, 0.5, 0.6, 0, 9])
        let stats = mo_queue_read_stats(q)
        XCTAssertEqual(stats.rendered_frames, 6)
        XCTAssertEqual(stats.high_water_frames, 4)
        XCTAssertEqual(stats.underruns, 1)
        XCTAssertFalse(stats.faulted)
    }
    func testBothEarsAndRenderSizesPreserveBitsAndCanaries() throws {
        for ear: UInt32 in [0, 1] {
            for capacity: UInt32 in [1, 2, 4, 4096] {
                for count in [1, 3, 256, 1024, 4096, 16384] {
                    let q = try XCTUnwrap(mo_queue_create(capacity, ear)); defer { mo_queue_destroy(q) }
                    let input = (0..<Int(capacity)).map { Float($0 % 101 - 50) / 100 }
                    XCTAssertEqual(push(q, input), capacity)
                    let result = render(q, count: count)
                    let selected = ear == 0 ? result.1 : result.2
                    let other = ear == 0 ? result.2 : result.1
                    let n = min(count, input.count)
                    XCTAssertEqual(Array(selected.prefix(n)).map(\.bitPattern), Array(input.prefix(n)).map(\.bitPattern))
                    XCTAssertTrue(selected[n..<count].allSatisfy { $0.bitPattern == 0 })
                    XCTAssertTrue(other.prefix(count).allSatisfy { $0.bitPattern == 0 })
                    XCTAssertEqual(selected.last, 9); XCTAssertEqual(other.last, 9)
                    XCTAssertEqual(mo_queue_read_stats(q).rendered_frames, UInt64(n))
                }
            }
        }
    }
    func testFixedSeedFIFOReference() throws {
        let q = try XCTUnwrap(mo_queue_create(16, 0)); defer { mo_queue_destroy(q) }
        var fifo: [Float] = [], state: UInt64 = 12345, rendered: UInt64 = 0, underruns: UInt64 = 0
        var highWater: UInt32 = 0
        func next() -> UInt64 { state = state &* 6364136223846793005 &+ 1; return state }
        for _ in 0..<4000 {
            let count = Int(next() % 31) + 1
            if next() & 16 != 0 {
                let values = (0..<count).map { _ in Float(next() % 60 + 1) / 100 }
                let n = min(count, 16 - fifo.count)
                XCTAssertEqual(push(q, values), UInt32(n))
                fifo.append(contentsOf: values.prefix(n))
                highWater = max(highWater, UInt32(fifo.count))
            } else {
                let n = min(count, fifo.count)
                let result = render(q, count: count)
                XCTAssertEqual(Array(result.1.prefix(count)), Array(fifo.prefix(n)) + Array(repeating: 0, count: count - n))
                XCTAssertEqual(result.0, n == count ? MO_RENDER_OK : MO_RENDER_UNDERRUN)
                fifo.removeFirst(n); rendered += UInt64(n)
                if n != count { underruns += 1 }
            }
        }
        let stats = mo_queue_read_stats(q)
        XCTAssertEqual(stats.rendered_frames, rendered)
        XCTAssertEqual(stats.underruns, underruns)
        XCTAssertEqual(stats.high_water_frames, highWater)
    }
    func testInvalidPCMRejectsEntireCandidateAndLatchesFault() throws {
        let peak = Float(pow(10.0, -3.0 / 20.0))
        for invalid in [Float.nan, .infinity, -.infinity, 4, -4, peak.nextUp, -peak.nextUp] {
            for index in 0..<3 {
                let q = try XCTUnwrap(mo_queue_create(4, 0)); defer { mo_queue_destroy(q) }
                var input: [Float] = [0.1, 0.2, 0.3]; input[index] = invalid
                XCTAssertEqual(push(q, input), 0)
                XCTAssertEqual(push(q, [0.1]), 0)
                let r = render(q, count: 3)
                XCTAssertEqual(r.0, MO_RENDER_FAULT)
                XCTAssertEqual(r.1, [0, 0, 0, 9]); XCTAssertEqual(r.2, [0, 0, 0, 9])
                let stats = mo_queue_read_stats(q)
                XCTAssertTrue(stats.faulted); XCTAssertTrue(stats.silenced)
                XCTAssertEqual(stats.invalid_samples, 1); XCTAssertEqual(stats.rendered_frames, 0)
                XCTAssertEqual(stats.underruns, 0)
                XCTAssertEqual(mo_queue_render(q, MOFloatBuffer(), MOFloatBuffer(), 0), MO_RENDER_OK)
                XCTAssertEqual(mo_queue_read_stats(q).invalid_buffers, 0)
            }
        }
    }
    func testPeakBoundaryAndSignedZeroPreserveBits() throws {
        let q = try XCTUnwrap(mo_queue_create(8, 0)); defer { mo_queue_destroy(q) }
        let peak = Float(pow(10.0, -3.0 / 20.0))
        let input: [Float] = [peak, -peak, peak.nextDown, -peak.nextDown, -0.0, 0.0]
        XCTAssertEqual(push(q, input), 6)
        XCTAssertEqual(Array(render(q, count: 6).1.prefix(6)).map(\.bitPattern), input.map(\.bitPattern))
    }
    func testOnlyAcceptedCandidatesAreInspected() throws {
        let q = try XCTUnwrap(mo_queue_create(2, 0)); defer { mo_queue_destroy(q) }
        XCTAssertEqual(push(q, [0.1, 0.2, .nan]), 2)
        XCTAssertEqual(push(q, [.nan]), 0)
        XCTAssertFalse(mo_queue_read_stats(q).faulted)
        _ = render(q, count: 2)
        XCTAssertEqual(push(q, [.nan, .infinity]), 0)
        XCTAssertEqual(mo_queue_read_stats(q).invalid_samples, 2)
    }
    func testSilenceIsIrreversibleAndNewQueueIndependent() throws {
        let q = try XCTUnwrap(mo_queue_create(2, 0)); defer { mo_queue_destroy(q) }
        XCTAssertEqual(push(q, [0, 0.1]), 2)
        _ = render(q, count: 1)
        mo_queue_silence(q); mo_queue_silence(q)
        for _ in 0..<3 {
            XCTAssertEqual(push(q, [0.2]), 0)
            let r = render(q, count: 3)
            XCTAssertEqual(r.0, MO_RENDER_SILENCED)
            XCTAssertEqual(r.1, [0, 0, 0, 9])
        }
        XCTAssertEqual(mo_queue_read_stats(q).rendered_frames, 1)
        XCTAssertEqual(mo_queue_read_stats(q).underruns, 0)
        let fresh = try XCTUnwrap(mo_queue_create(2, 1)); defer { mo_queue_destroy(fresh) }
        XCTAssertEqual(push(fresh, [0.2]), 1)
        XCTAssertEqual(render(fresh, count: 1).2, [0.2, 9])
    }
    func testInvalidPushRequestsLatchFault() throws {
        for oversized in [false, true] {
            let q = try XCTUnwrap(mo_queue_create(1, 0)); defer { mo_queue_destroy(q) }
            var value: Float = 0.1
            let result = oversized ? mo_queue_push(q, &value, 4097) : mo_queue_push(q, nil, 1)
            XCTAssertEqual(result, 0)
            XCTAssertTrue(mo_queue_read_stats(q).faulted)
            XCTAssertEqual(mo_queue_read_stats(q).invalid_buffers, 1)
        }
    }
    func testInvalidRenderBoundsAndCanaries() throws {
        // Every case has real backing storage; declared short ranges constrain zeroing.
        for kind in 0..<5 {
            let q = try XCTUnwrap(mo_queue_create(2, 0)); defer { mo_queue_destroy(q) }
            var left = [Float](repeating: 9, count: 16386), right = left
            let result = left.withUnsafeMutableBufferPointer { l in
                right.withUnsafeMutableBufferPointer { r in
                    mo_queue_render(q,
                        MOFloatBuffer(data: kind == 1 ? nil : l.baseAddress, capacity: kind == 0 ? 1 : 16385),
                        MOFloatBuffer(data: kind == 2 ? l.baseAddress : kind == 3 ? l.baseAddress! + 1 : r.baseAddress, capacity: 16385),
                        kind == 4 ? 16385 : 3)
                }
            }
            XCTAssertEqual(result, MO_RENDER_FAULT)
            XCTAssertEqual(left.last, 9); XCTAssertEqual(right.last, 9)
            if kind == 0 { XCTAssertEqual(left[0], 0); XCTAssertEqual(left[1], 9) }
            if kind == 4 { XCTAssertEqual(left[16383], 0); XCTAssertEqual(left[16384], 9) }
            XCTAssertEqual(mo_queue_read_stats(q).invalid_buffers, 1)
        }
    }
    func testDeclaredCapacityOverlapBeyondWrittenPrefixFaults() throws {
        let q = try XCTUnwrap(mo_queue_create(2, 0)); defer { mo_queue_destroy(q) }
        var storage = [Float](repeating: 9, count: 9)
        let result = storage.withUnsafeMutableBufferPointer { b in
            mo_queue_render(q, MOFloatBuffer(data: b.baseAddress, capacity: 5),
                            MOFloatBuffer(data: b.baseAddress! + 4, capacity: 4), 1)
        }
        XCTAssertEqual(result, MO_RENDER_FAULT)
        XCTAssertEqual(storage, [0, 9, 9, 9, 0, 9, 9, 9, 9])
    }
    func testUnalignedAndOverflowOutputNeverDereferenced() throws {
        for overflow in [false, true] {
            let q = try XCTUnwrap(mo_queue_create(2, 0)); defer { mo_queue_destroy(q) }
            let bytes = UnsafeMutableRawPointer.allocate(byteCount: 32, alignment: 16)
            defer { bytes.deallocate() }
            bytes.initializeMemory(as: UInt8.self, repeating: 0x5A, count: 32)
            let invalid = overflow
                ? UnsafeMutablePointer<Float>(bitPattern: UInt.max - 3)!
                : bytes.advanced(by: 1).assumingMemoryBound(to: Float.self)
            var right: [Float] = [9, 9]
            let result = right.withUnsafeMutableBufferPointer {
                mo_queue_render(q, MOFloatBuffer(data: invalid, capacity: 2),
                                MOFloatBuffer(data: $0.baseAddress, capacity: 2), 1)
            }
            XCTAssertEqual(result, MO_RENDER_FAULT)
            XCTAssertEqual(right, [0, 9])
            XCTAssertTrue(UnsafeRawBufferPointer(start: bytes, count: 32).allSatisfy { $0 == 0x5A })
        }
    }
    func testNullQueueNonzeroRenderClearsReachableOutput() {
        let r = render(nil, count: 2)
        XCTAssertEqual(r.0, MO_RENDER_FAULT)
        XCTAssertEqual(r.1, [0, 0, 9]); XCTAssertEqual(r.2, [0, 0, 9])
    }
    private func push(_ q: OpaquePointer, _ input: [Float]) -> UInt32 {
        input.withUnsafeBufferPointer { mo_queue_push(q, $0.baseAddress, UInt32($0.count)) }
    }
    private func render(_ q: OpaquePointer?, count: Int) -> (MORenderResult, [Float], [Float]) {
        var left = [Float](repeating: 9, count: count + 1)
        var right = left
        let result = left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                mo_queue_render(q, MOFloatBuffer(data: l.baseAddress, capacity: UInt32(l.count)), MOFloatBuffer(data: r.baseAddress, capacity: UInt32(r.count)), UInt32(count))
            }
        }
        return (result, left, right)
    }
}

// All thread ownership stays inside the C test harness. No Sendable pointer escape.
extension FrameQueueTests {
    func testConcurrentMillionFrameOrder() { XCTAssertEqual(mo_test_concurrent_order(), 0) }
    func testThousandJoinedLifecycles() { XCTAssertEqual(mo_test_lifecycle(), 0) }
    func testInjectedContractsAndSilenceBoundaries() { XCTAssertEqual(mo_test_injected_contracts(), 0) }
}
