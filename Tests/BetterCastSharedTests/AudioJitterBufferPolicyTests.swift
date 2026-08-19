import XCTest
@testable import BetterCastShared

final class AudioJitterBufferPolicyTests: XCTestCase {
    func testFirstStartWaitsForFivePackets() {
        var state = AudioJitterBufferState()
        for _ in 0..<4 {
            XCTAssertFalse(state.bufferScheduled())
        }

        XCTAssertTrue(state.bufferScheduled())
        XCTAssertTrue(state.isPlaying)
        XCTAssertEqual(state.pendingBuffers, 5)
    }

    func testUnderrunReturnsToBufferingAndUsesSameResumeThreshold() {
        var state = AudioJitterBufferState()
        for _ in 0..<5 { _ = state.bufferScheduled() }
        let generation = state.playbackGeneration
        for _ in 0..<4 {
            XCTAssertFalse(state.bufferCompleted(scheduledIn: generation))
        }

        XCTAssertTrue(state.bufferCompleted(scheduledIn: generation))
        XCTAssertFalse(state.isPlaying)
        XCTAssertEqual(state.pendingBuffers, 0)

        for _ in 0..<4 {
            XCTAssertFalse(state.bufferScheduled())
        }
        XCTAssertTrue(state.bufferScheduled())
        XCTAssertTrue(state.isPlaying)
    }

    func testMaximumQueueCapsDecodedLatency() {
        var state = AudioJitterBufferState()
        for _ in 0..<AudioJitterBufferState.maxPendingBuffers {
            XCTAssertFalse(state.shouldDropIncomingBuffer)
            _ = state.bufferScheduled()
        }
        XCTAssertTrue(state.shouldDropIncomingBuffer)
    }

    func testResetClearsPlaybackState() {
        var state = AudioJitterBufferState()
        for _ in 0..<5 { _ = state.bufferScheduled() }
        let oldGeneration = state.playbackGeneration
        state.reset()

        XCTAssertEqual(state.pendingBuffers, 0)
        XCTAssertFalse(state.isPlaying)
        XCTAssertEqual(state.playbackGeneration, oldGeneration &+ 1)
    }

    func testCompletionFromPreviousPlaybackGenerationIsIgnored() {
        var state = AudioJitterBufferState()
        for _ in 0..<5 { _ = state.bufferScheduled() }
        let oldGeneration = state.playbackGeneration

        state.reset()
        for _ in 0..<5 { _ = state.bufferScheduled() }

        XCTAssertFalse(state.bufferCompleted(scheduledIn: oldGeneration))
        XCTAssertEqual(state.pendingBuffers, 5)
        XCTAssertTrue(state.isPlaying)
    }
}
