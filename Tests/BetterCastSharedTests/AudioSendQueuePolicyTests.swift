import XCTest
@testable import BetterCastShared

final class AudioSendQueuePolicyTests: XCTestCase {
    func testQueuePreservesFIFOOrder() {
        var queue = BoundedAudioPacketFIFO(capacity: 3)
        queue.enqueue(Data([1]))
        queue.enqueue(Data([2]))
        queue.enqueue(Data([3]))

        XCTAssertEqual(queue.dequeue(), Data([1]))
        XCTAssertEqual(queue.dequeue(), Data([2]))
        XCTAssertEqual(queue.dequeue(), Data([3]))
        XCTAssertNil(queue.dequeue())
    }

    func testFullQueueDropsOldestPendingPacket() {
        var queue = BoundedAudioPacketFIFO(capacity: 3)
        queue.enqueue(Data([1]))
        queue.enqueue(Data([2]))
        queue.enqueue(Data([3]))

        XCTAssertEqual(queue.enqueue(Data([4])), Data([1]))
        XCTAssertEqual(queue.packets, [Data([2]), Data([3]), Data([4])])
    }

    func testTotalAudioBudgetIsEightPacketsIncludingInFlight() {
        XCTAssertEqual(AudioSendQueuePolicy.maxBufferedPackets, 8)
        XCTAssertEqual(AudioSendQueuePolicy.maxPendingPacketsWhileSending, 7)
    }

    func testQueueNeverExceedsCapacityDuringSustainedCongestion() {
        var queue = BoundedAudioPacketFIFO(capacity: 7)
        var dropped = 0
        for value in 0..<100 {
            if queue.enqueue(Data([UInt8(value)])) != nil {
                dropped += 1
            }
        }

        XCTAssertEqual(queue.count, 7)
        XCTAssertEqual(dropped, 93)
        XCTAssertEqual(queue.packets.first, Data([93]))
        XCTAssertEqual(queue.packets.last, Data([99]))
    }
}
