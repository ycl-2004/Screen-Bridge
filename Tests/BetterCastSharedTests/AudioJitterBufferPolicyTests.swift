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
        for _ in 0..<4 {
            XCTAssertFalse(state.bufferCompleted())
        }

        XCTAssertTrue(state.bufferCompleted())
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
        state.reset()

        XCTAssertEqual(state, AudioJitterBufferState())
    }
}
