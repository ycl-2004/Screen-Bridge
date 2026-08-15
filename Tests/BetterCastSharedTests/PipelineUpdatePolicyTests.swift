import XCTest
@testable import BetterCastShared

final class PipelineUpdatePolicyTests: XCTestCase {
    private let baseline = PipelineSettingsSnapshot(
        useVirtualDisplay: true,
        resolutionIdentifier: "Best Fit",
        usesRetinaBacking: true,
        qualityBitrate: 20_000_000,
        audioEnabled: false
    )

    func testAudioOnlyChangeDoesNotRebuildDisplay() {
        let requested = PipelineSettingsSnapshot(
            useVirtualDisplay: true,
            resolutionIdentifier: "Best Fit",
            usesRetinaBacking: true,
            qualityBitrate: 20_000_000,
            audioEnabled: true
        )

        XCTAssertEqual(PipelineUpdatePolicy.actions(from: baseline, to: requested), [.reconcileAudio])
    }

    func testQualityOnlyChangeUpdatesEncoderInPlace() {
        let requested = PipelineSettingsSnapshot(
            useVirtualDisplay: true,
            resolutionIdentifier: "Best Fit",
            usesRetinaBacking: true,
            qualityBitrate: 50_000_000,
            audioEnabled: false
        )

        XCTAssertEqual(PipelineUpdatePolicy.actions(from: baseline, to: requested), [.updateBitrate])
    }

    func testDisplayChangeSupersedesInPlaceActions() {
        let requested = PipelineSettingsSnapshot(
            useVirtualDisplay: false,
            resolutionIdentifier: "1920 x 1080",
            usesRetinaBacking: false,
            qualityBitrate: 50_000_000,
            audioEnabled: true
        )

        XCTAssertEqual(PipelineUpdatePolicy.actions(from: baseline, to: requested), [.rebuildDisplay])
    }

    func testNoChangeNeedsNoWork() {
        XCTAssertTrue(PipelineUpdatePolicy.actions(from: baseline, to: baseline).isEmpty)
    }
}
