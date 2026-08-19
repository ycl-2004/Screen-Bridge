import CoreAudio
import XCTest
@testable import BetterCastSenderSupport

final class AudioApplicationCatalogTests: XCTestCase {
    func testHelperProcessGroupsUnderOwningRegularApplication() {
        let processes = [
            AudioProcessRecord(
                objectID: 10,
                pid: 101,
                bundleIdentifier: "com.google.Chrome.helper",
                isRunningOutput: true
            )
        ]
        let runningApplications = [
            RunningApplicationRecord(
                pid: 100,
                processBundleIdentifier: "com.google.Chrome",
                bundleIdentifier: "com.google.Chrome",
                displayName: "Google Chrome",
                bundlePath: "/Applications/Google Chrome.app",
                isRegular: true
            )
        ]

        let applications = AudioApplicationCatalog.groupedApplications(
            processes: processes,
            runningApplications: runningApplications
        )

        XCTAssertEqual(applications.count, 1)
        XCTAssertEqual(applications[0].id, "com.google.Chrome")
        XCTAssertEqual(applications[0].displayName, "Google Chrome")
        XCTAssertEqual(applications[0].processBundleIdentifiers, ["com.google.Chrome.helper"])
        XCTAssertTrue(applications[0].isRunningOutput)
    }

    func testExactHelperPIDUsesOutermostApplicationIdentity() {
        let processes = [
            AudioProcessRecord(
                objectID: 20,
                pid: 201,
                bundleIdentifier: "com.spotify.client.helper",
                isRunningOutput: true
            )
        ]
        let runningApplications = [
            RunningApplicationRecord(
                pid: 201,
                processBundleIdentifier: "com.spotify.client.helper",
                bundleIdentifier: "com.spotify.client",
                displayName: "Spotify",
                bundlePath: "/Applications/Spotify.app",
                isRegular: false
            )
        ]

        let applications = AudioApplicationCatalog.groupedApplications(
            processes: processes,
            runningApplications: runningApplications
        )

        XCTAssertEqual(applications.map(\.id), ["com.spotify.client"])
        XCTAssertEqual(applications.first?.displayName, "Spotify")
    }

    func testSharedWebKitAudioProcessUsesLocalizedHostApplication() {
        let processes = [
            AudioProcessRecord(
                objectID: 25,
                pid: 251,
                bundleIdentifier: "com.apple.WebKit.GPU",
                isRunningOutput: true
            )
        ]
        let runningApplications = [
            RunningApplicationRecord(
                pid: 250,
                processBundleIdentifier: "com.apple.Safari",
                bundleIdentifier: "com.apple.Safari",
                displayName: "Safari",
                bundlePath: "/System/Applications/Safari.app",
                isRegular: true
            ),
            RunningApplicationRecord(
                pid: 251,
                processBundleIdentifier: "com.apple.WebKit.GPU",
                bundleIdentifier: "com.apple.WebKit.GPU",
                displayName: "Safari Graphics and Media",
                bundlePath: nil,
                isRegular: false
            )
        ]

        let applications = AudioApplicationCatalog.groupedApplications(
            processes: processes,
            runningApplications: runningApplications
        )

        XCTAssertEqual(applications.map(\.id), ["com.apple.Safari"])
        XCTAssertEqual(applications.first?.displayName, "Safari")
        XCTAssertEqual(applications.first?.bundlePath, "/System/Applications/Safari.app")
    }

    func testProcessesForOneAppAreMixedIntoOneCatalogEntry() {
        let processes = [
            AudioProcessRecord(
                objectID: 30,
                pid: 301,
                bundleIdentifier: "com.example.Player",
                isRunningOutput: false
            ),
            AudioProcessRecord(
                objectID: 31,
                pid: 302,
                bundleIdentifier: "com.example.Player.helper",
                isRunningOutput: true
            )
        ]
        let runningApplications = [
            RunningApplicationRecord(
                pid: 301,
                processBundleIdentifier: "com.example.Player",
                bundleIdentifier: "com.example.Player",
                displayName: "Player",
                bundlePath: "/Applications/Player.app",
                isRegular: true
            )
        ]

        let applications = AudioApplicationCatalog.groupedApplications(
            processes: processes,
            runningApplications: runningApplications
        )

        XCTAssertEqual(applications.count, 1)
        XCTAssertEqual(
            applications[0].processBundleIdentifiers,
            ["com.example.Player", "com.example.Player.helper"]
        )
        XCTAssertTrue(applications[0].isRunningOutput)
    }

    func testRouteAssignmentMovesAnAppToOneDestination() throws {
        let app = AudioApplicationInfo(
            id: "com.spotify.client",
            bundleIdentifier: "com.spotify.client",
            displayName: "Spotify",
            bundlePath: "/Applications/Spotify.app",
            processBundleIdentifiers: ["com.spotify.client"],
            isRunningOutput: true
        )

        var assignments = AudioRouteAssignments.assigning(
            app,
            to: "ipad-a",
            destinationName: "Living Room iPad",
            in: [:]
        )
        assignments = AudioRouteAssignments.assigning(
            app,
            to: "ipad-b",
            destinationName: "Desk iPad",
            in: assignments
        )

        XCTAssertTrue(AudioRouteAssignments.applicationIDs(routedTo: "ipad-a", in: assignments).isEmpty)
        XCTAssertEqual(
            AudioRouteAssignments.applicationIDs(routedTo: "ipad-b", in: assignments),
            ["com.spotify.client"]
        )

        let data = try JSONEncoder().encode(assignments)
        XCTAssertEqual(try JSONDecoder().decode([String: AudioRouteAssignment].self, from: data), assignments)
    }

    func testMutedCaptureWaitsForAuthenticatedTransport() {
        XCTAssertEqual(
            AudioPipelineReadinessPolicy.action(
                hasSelectedApplications: true,
                receiverIsBackgrounded: false,
                hasTransport: true,
                transportIsAuthenticated: false,
                captureIsRunning: false
            ),
            .waitForTransportAuthentication
        )
        XCTAssertEqual(
            AudioPipelineReadinessPolicy.action(
                hasSelectedApplications: true,
                receiverIsBackgrounded: false,
                hasTransport: true,
                transportIsAuthenticated: true,
                captureIsRunning: false
            ),
            .startCapture
        )
    }

    func testBackgroundOrNoSelectionRestoresLocalAudio() {
        XCTAssertEqual(
            AudioPipelineReadinessPolicy.action(
                hasSelectedApplications: true,
                receiverIsBackgrounded: true,
                hasTransport: true,
                transportIsAuthenticated: true,
                captureIsRunning: true
            ),
            .stopAndRestoreLocalAudio
        )
        XCTAssertEqual(
            AudioPipelineReadinessPolicy.action(
                hasSelectedApplications: false,
                receiverIsBackgrounded: false,
                hasTransport: true,
                transportIsAuthenticated: true,
                captureIsRunning: true
            ),
            .stopAndRestoreLocalAudio
        )
    }
}
