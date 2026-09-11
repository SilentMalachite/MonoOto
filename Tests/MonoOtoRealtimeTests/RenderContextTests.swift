import XCTest
import AudioToolbox
import MonoOtoRealtime
import MonoOtoRealtimeTestSupport

final class RenderContextTests: XCTestCase {
    func testContextOutlivesInFlightRender() {
        XCTAssertEqual(mo_test_render_context_barriers(1), 0,
            "After actual C entry, hold/stop must preserve context until joined and consume no PCM")
    }
    func testHoldAfterQueueReturnKeepsAlreadyRenderedPCMCounted() {
        XCTAssertEqual(mo_test_render_context_barriers(2), 0,
            "PCM already past queue final gate remains counted once; following call is silence")
    }

    func testHoldDoesNotConsumePCM() throws {
        let q = try XCTUnwrap(mo_queue_create(8, 0)); defer { mo_queue_destroy(q) }
        let c = try XCTUnwrap(mo_render_context_create(q)); defer { mo_render_context_destroy(c) }
        let samples: [Float] = [0, 0.25, -0.5]
        samples.withUnsafeBufferPointer { XCTAssertEqual(mo_queue_push(q, $0.baseAddress, 3), 3) }
        withBuffers { abl, left, right in
            var silent = false
            XCTAssertEqual(mo_render_context_render(c, abl, 4, &silent), MO_RENDER_SILENCED)
            XCTAssertTrue(silent); XCTAssertEqual(mo_queue_read_stats(q).rendered_frames, 0)
            XCTAssertTrue(mo_render_context_set_hold(c, false))
            XCTAssertEqual(mo_render_context_render(c, abl, 4, &silent), MO_RENDER_UNDERRUN)
            XCTAssertFalse(silent)
            XCTAssertEqual(Array(UnsafeBufferPointer(start: left, count: 4)), [0, 0.25, -0.5, 0])
            XCTAssertEqual(Array(UnsafeBufferPointer(start: right, count: 4)), [0, 0, 0, 0])
            XCTAssertEqual(mo_queue_read_stats(q).rendered_frames, 3)
        }
        XCTAssertEqual(mo_render_context_read_stats(c).active_callbacks, 0)
        XCTAssertEqual(mo_render_context_read_stats(c).entries, 2)
        XCTAssertEqual(mo_render_context_read_stats(c).exits, 2)
    }
    func testFaultCannotResume() throws {
        let q = try XCTUnwrap(mo_queue_create(8, 0)); defer { mo_queue_destroy(q) }
        let c = try XCTUnwrap(mo_render_context_create(q)); defer { mo_render_context_destroy(c) }
        withBuffers { abl, _, _ in
            abl.pointee.mBuffers.mNumberChannels = 2
            var silent = false
            XCTAssertEqual(mo_render_context_render(c, abl, 4, &silent), MO_RENDER_FAULT)
        }
        XCTAssertTrue(mo_queue_read_stats(q).silenced)
        XCTAssertTrue(mo_render_context_read_stats(c).faulted)
        XCTAssertFalse(mo_render_context_set_hold(c, false))
    }
    func testMalformedABLSilencesReachableBuffers() throws {
        let q = try XCTUnwrap(mo_queue_create(8, 0)); defer { mo_queue_destroy(q) }
        let c = try XCTUnwrap(mo_render_context_create(q)); defer { mo_render_context_destroy(c) }
        withBuffers { abl, left, right in
            abl.pointee.mNumberBuffers = 3
            var silent = true
            XCTAssertEqual(mo_render_context_render(c, abl, 4, &silent), MO_RENDER_FAULT)
            XCTAssertFalse(silent)
            XCTAssertEqual(left[0], 0); XCTAssertEqual(right[3], 0)
        }
    }
    func testZeroFramesDoesNotTouchQueue() throws {
        let q = try XCTUnwrap(mo_queue_create(8, 0)); defer { mo_queue_destroy(q) }
        let c = try XCTUnwrap(mo_render_context_create(q)); defer { mo_render_context_destroy(c) }
        var silent = false
        XCTAssertEqual(mo_render_context_render(c, nil, 0, &silent), MO_RENDER_OK)
        XCTAssertTrue(silent); XCTAssertFalse(mo_queue_read_stats(q).silenced)
        XCTAssertEqual(mo_render_context_read_stats(c).entries, 0)
    }
    func testInvalidLayoutsAndDeclaredRangesFailClosed() throws {
        for kind in 0..<6 {
            let q = try XCTUnwrap(mo_queue_create(8, 0)); defer { mo_queue_destroy(q) }
            let c = try XCTUnwrap(mo_render_context_create(q)); defer { mo_render_context_destroy(c) }
            withBuffers { abl, left, right in
                let list = UnsafeMutableAudioBufferListPointer(abl)
                switch kind {
                case 0: list[0].mDataByteSize = 4
                case 1: list[0].mDataByteSize = 15
                case 2: list[0].mData = nil
                case 3: list[0].mData = UnsafeMutableRawPointer(left).advanced(by: 1)
                case 4: list[1].mData = UnsafeMutableRawPointer(left)
                default: break
                }
                var silent = true
                XCTAssertEqual(mo_render_context_render(c, abl, kind == 5 ? 16_385 : 4, &silent), MO_RENDER_FAULT)
                XCTAssertFalse(silent)
                XCTAssertTrue(mo_queue_read_stats(q).silenced)
                XCTAssertFalse(mo_render_context_set_hold(c, false))
                if kind != 4 { XCTAssertEqual(right[3], 0) }
                if kind == 0 { XCTAssertEqual(left[0], 0); XCTAssertEqual(left[1], 9) }
            }
        }
    }
    func testRealZerosCountAsPCMAndSilencedQueueCannotResume() throws {
        let q = try XCTUnwrap(mo_queue_create(8, 1)); defer { mo_queue_destroy(q) }
        let c = try XCTUnwrap(mo_render_context_create(q)); defer { mo_render_context_destroy(c) }
        let samples: [Float] = [0, 0]
        samples.withUnsafeBufferPointer { XCTAssertEqual(mo_queue_push(q, $0.baseAddress, 2), 2) }
        XCTAssertTrue(mo_render_context_set_hold(c, false))
        withBuffers { abl, _, _ in
            var silent = false
            XCTAssertEqual(mo_render_context_render(c, abl, 4, &silent), MO_RENDER_UNDERRUN)
            XCTAssertTrue(silent)
            XCTAssertEqual(mo_queue_read_stats(q).rendered_frames, 2)
        }
        mo_queue_silence(q)
        XCTAssertFalse(mo_render_context_set_hold(c, false))
    }
    private func withBuffers(_ body: (UnsafeMutablePointer<AudioBufferList>, UnsafeMutablePointer<Float>, UnsafeMutablePointer<Float>) -> Void) {
        let list = AudioBufferList.allocate(maximumBuffers: 2); defer { list.unsafeMutablePointer.deallocate() }
        let left = UnsafeMutablePointer<Float>.allocate(capacity: 4)
        let right = UnsafeMutablePointer<Float>.allocate(capacity: 4)
        defer { left.deallocate(); right.deallocate() }
        left.initialize(repeating: 9, count: 4); right.initialize(repeating: 9, count: 4)
        list[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 16, mData: left)
        list[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 16, mData: right)
        body(list.unsafeMutablePointer, left, right)
    }
}
