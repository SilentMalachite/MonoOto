import XCTest
@testable import MonoOtoCore

final class PlaybackStateTests: XCTestCase {
    @MainActor
    func testPreparationMustFinishBeforeCurrentTicketCanStart() {
        let state = PlaybackState()

        let ticket = state.beginPreparation()

        XCTAssertEqual(state.phase, .preparing)
        XCTAssertFalse(state.start(ticket))
        XCTAssertTrue(state.finishPreparation(ticket))
        XCTAssertEqual(state.phase, .preparing)
        XCTAssertTrue(state.start(ticket))
        XCTAssertEqual(state.phase, .running)
    }

    @MainActor
    func testLatePreparationCannotRestartPlaybackAfterStop() {
        let state = PlaybackState()
        let old = state.beginPreparation()

        state.stop()

        XCTAssertFalse(state.finishPreparation(old))
        XCTAssertFalse(state.start(old))
        XCTAssertEqual(state.phase, .stopped)
    }

    @MainActor
    func testNewPreparationSupersedesOldTicketWithoutChangingNewState() {
        let state = PlaybackState()
        let old = state.beginPreparation()
        let current = state.beginPreparation()

        XCTAssertEqual(current.generation, old.generation + 1)
        XCTAssertFalse(state.finishPreparation(old))
        XCTAssertEqual(state.phase, .preparing)
        XCTAssertTrue(state.finishPreparation(current))
        XCTAssertTrue(state.start(current))
        XCTAssertEqual(state.phase, .running)
    }

    @MainActor
    func testLateCompletionCannotAlterRunningNewGeneration() {
        let state = PlaybackState()
        let old = state.beginPreparation()
        let current = state.beginPreparation()
        XCTAssertTrue(state.finishPreparation(current))
        XCTAssertTrue(state.start(current))

        XCTAssertFalse(state.finishPreparation(old))
        XCTAssertFalse(state.start(old))
        XCTAssertEqual(state.phase, .running)
    }

    @MainActor
    func testPauseInvalidatesTicketAndRequiresFreshPreparation() {
        let state = PlaybackState()
        let old = state.beginPreparation()
        XCTAssertTrue(state.finishPreparation(old))
        XCTAssertTrue(state.start(old))

        state.pause()

        XCTAssertEqual(state.phase, .paused)
        XCTAssertFalse(state.finishPreparation(old))
        XCTAssertFalse(state.start(old))

        let current = state.beginPreparation()
        XCTAssertEqual(current.generation, old.generation + 2)
        XCTAssertEqual(state.phase, .preparing)
    }

    @MainActor
    func testCurrentFailureEntersErrorAndInvalidatesTicket() {
        let state = PlaybackState()
        let ticket = state.beginPreparation()

        XCTAssertTrue(state.fail(ticket))
        XCTAssertEqual(state.phase, .error)
        XCTAssertFalse(state.finishPreparation(ticket))
        XCTAssertFalse(state.start(ticket))
    }

    @MainActor
    func testStaleFailureCannotAlterCurrentPreparation() {
        let state = PlaybackState()
        let stale = state.beginPreparation()
        let current = state.beginPreparation()

        XCTAssertFalse(state.fail(stale))
        XCTAssertEqual(state.phase, .preparing)
        XCTAssertTrue(state.finishPreparation(current))
    }
}
