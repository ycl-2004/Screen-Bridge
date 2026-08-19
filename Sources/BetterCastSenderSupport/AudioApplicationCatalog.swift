import AppKit
import CoreAudio
import Foundation

public struct AudioApplicationInfo: Identifiable, Equatable, Sendable {
    public let id: String
    public let bundleIdentifier: String
    public let displayName: String
    public let bundlePath: String?
    public let processBundleIdentifiers: [String]
    public let isRunningOutput: Bool

    public init(
        id: String,
        bundleIdentifier: String,
        displayName: String,
        bundlePath: String?,
        processBundleIdentifiers: [String],
        isRunningOutput: Bool
    ) {
        self.id = id
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.bundlePath = bundlePath
        self.processBundleIdentifiers = processBundleIdentifiers
        self.isRunningOutput = isRunningOutput
    }
}

public struct AudioRouteAssignment: Codable, Equatable, Sendable {
    public let applicationID: String
    public let applicationName: String
    public let applicationBundlePath: String?
    public let destinationID: String
    public let destinationName: String

    public init(
        applicationID: String,
        applicationName: String,
        applicationBundlePath: String?,
        destinationID: String,
        destinationName: String
    ) {
        self.applicationID = applicationID
        self.applicationName = applicationName
        self.applicationBundlePath = applicationBundlePath
        self.destinationID = destinationID
        self.destinationName = destinationName
    }
}

public enum AudioRouteAssignments {
    public static func assigning(
        _ application: AudioApplicationInfo,
        to destinationID: String,
        destinationName: String,
        in assignments: [String: AudioRouteAssignment]
    ) -> [String: AudioRouteAssignment] {
        var updated = assignments
        updated[application.id] = AudioRouteAssignment(
            applicationID: application.id,
            applicationName: application.displayName,
            applicationBundlePath: application.bundlePath,
            destinationID: destinationID,
            destinationName: destinationName
        )
        return updated
    }

    public static func removing(
        applicationID: String,
        from assignments: [String: AudioRouteAssignment]
    ) -> [String: AudioRouteAssignment] {
        var updated = assignments
        updated.removeValue(forKey: applicationID)
        return updated
    }

    public static func applicationIDs(
        routedTo destinationID: String,
        in assignments: [String: AudioRouteAssignment]
    ) -> Set<String> {
        Set(
            assignments.values.lazy
                .filter { $0.destinationID == destinationID }
                .map(\.applicationID)
        )
    }
}

public enum AudioPipelineReadinessAction: Equatable, Sendable {
    case stopAndRestoreLocalAudio
    case connectTransport
    case waitForTransportAuthentication
    case startCapture
    case keepStreaming
}

public enum AudioPipelineReadinessPolicy {
    public static func action(
        hasSelectedApplications: Bool,
        receiverIsBackgrounded: Bool,
        hasTransport: Bool,
        transportIsAuthenticated: Bool,
        captureIsRunning: Bool
    ) -> AudioPipelineReadinessAction {
        guard hasSelectedApplications, !receiverIsBackgrounded else {
            return .stopAndRestoreLocalAudio
        }
        if captureIsRunning {
            return .keepStreaming
        }
        guard hasTransport else { return .connectTransport }
        guard transportIsAuthenticated else { return .waitForTransportAuthentication }
        return .startCapture
    }
}

public enum AudioApplicationCatalogError: LocalizedError {
    case processListUnavailable(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .processListUnavailable(let status):
            return "Unable to read the Core Audio process list (\(status))"
        }
    }
}

public enum AudioApplicationCatalog {
    public static func applications() throws -> [AudioApplicationInfo] {
        let processes = try audioProcesses()
        let runningApplications = currentRunningApplications()
        let senderBundleIdentifier = Bundle.main.bundleIdentifier

        return groupedApplications(processes: processes, runningApplications: runningApplications)
            .filter { $0.bundleIdentifier != senderBundleIdentifier }
    }

    public static func processObjectIDs(
        matchingApplicationIDs applicationIDs: Set<String>
    ) throws -> [AudioObjectID] {
        guard !applicationIDs.isEmpty else { return [] }
        let processes = try audioProcesses()
        let runningApplications = currentRunningApplications()

        return processes.compactMap { process in
            let identity = resolvedIdentity(for: process, runningApplications: runningApplications)
            return applicationIDs.contains(identity.bundleIdentifier) ? process.objectID : nil
        }
    }

    static func groupedApplications(
        processes: [AudioProcessRecord],
        runningApplications: [RunningApplicationRecord]
    ) -> [AudioApplicationInfo] {
        struct Aggregate {
            var identity: ApplicationIdentity
            var processBundleIdentifiers: Set<String>
            var isRunningOutput: Bool
        }

        var aggregates: [String: Aggregate] = [:]
        for process in processes {
            let identity = resolvedIdentity(for: process, runningApplications: runningApplications)
            guard !identity.bundleIdentifier.isEmpty else { continue }

            if var aggregate = aggregates[identity.bundleIdentifier] {
                aggregate.processBundleIdentifiers.insert(process.bundleIdentifier)
                aggregate.isRunningOutput = aggregate.isRunningOutput || process.isRunningOutput
                if aggregate.identity.bundlePath == nil, identity.bundlePath != nil {
                    aggregate.identity = identity
                }
                aggregates[identity.bundleIdentifier] = aggregate
            } else {
                aggregates[identity.bundleIdentifier] = Aggregate(
                    identity: identity,
                    processBundleIdentifiers: [process.bundleIdentifier],
                    isRunningOutput: process.isRunningOutput
                )
            }
        }

        return aggregates.values.map { aggregate in
            AudioApplicationInfo(
                id: aggregate.identity.bundleIdentifier,
                bundleIdentifier: aggregate.identity.bundleIdentifier,
                displayName: aggregate.identity.displayName,
                bundlePath: aggregate.identity.bundlePath,
                processBundleIdentifiers: aggregate.processBundleIdentifiers.sorted(),
                isRunningOutput: aggregate.isRunningOutput
            )
        }
        .sorted {
            if $0.isRunningOutput != $1.isRunningOutput {
                return $0.isRunningOutput && !$1.isRunningOutput
            }
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    private static func audioProcesses() throws -> [AudioProcessRecord] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        )
        guard status == noErr else {
            throw AudioApplicationCatalogError.processListUnavailable(status)
        }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var objectIDs = [AudioObjectID](repeating: kAudioObjectUnknown, count: count)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &objectIDs
        )
        guard status == noErr else {
            throw AudioApplicationCatalogError.processListUnavailable(status)
        }

        return objectIDs.compactMap { objectID in
            guard objectID != kAudioObjectUnknown,
                  let bundleIdentifier = stringProperty(
                    objectID,
                    selector: kAudioProcessPropertyBundleID
                  ),
                  !bundleIdentifier.isEmpty else {
                return nil
            }

            return AudioProcessRecord(
                objectID: objectID,
                pid: pidProperty(objectID) ?? 0,
                bundleIdentifier: bundleIdentifier,
                isRunningOutput: uint32Property(
                    objectID,
                    selector: kAudioProcessPropertyIsRunningOutput
                ) != 0
            )
        }
    }

    private static func currentRunningApplications() -> [RunningApplicationRecord] {
        NSWorkspace.shared.runningApplications.map { application in
            let outerURL = outermostApplicationURL(application.bundleURL)
            let outerBundle = outerURL.flatMap(Bundle.init(url:))
            return RunningApplicationRecord(
                pid: application.processIdentifier,
                processBundleIdentifier: application.bundleIdentifier,
                bundleIdentifier: outerBundle?.bundleIdentifier ?? application.bundleIdentifier,
                displayName: outerBundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                    ?? outerBundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
                    ?? application.localizedName,
                bundlePath: outerURL?.path ?? application.bundleURL?.path,
                isRegular: application.activationPolicy == .regular
            )
        }
    }

    private static func resolvedIdentity(
        for process: AudioProcessRecord,
        runningApplications: [RunningApplicationRecord]
    ) -> ApplicationIdentity {
        if let exactProcess = runningApplications.first(where: { $0.pid == process.pid }) {
            // WebKit and similar shared XPC services expose their own generic
            // bundle ID (for example `com.apple.WebKit.GPU`) even though the
            // user-facing owner is Safari, Raycast, or another regular app.
            // AppKit prefixes the helper's localized name with that owner
            // ("Safari Graphics and Media"), so prefer the longest matching
            // regular app name before falling back to the helper identity.
            if let owningApplication = owningRegularApplication(
                for: exactProcess,
                among: runningApplications
            ),
               let bundleIdentifier = owningApplication.bundleIdentifier {
                return ApplicationIdentity(
                    bundleIdentifier: bundleIdentifier,
                    displayName: owningApplication.displayName ?? fallbackName(for: bundleIdentifier),
                    bundlePath: owningApplication.bundlePath
                )
            }

            if let bundleIdentifier = exactProcess.bundleIdentifier {
                return ApplicationIdentity(
                    bundleIdentifier: bundleIdentifier,
                    displayName: exactProcess.displayName ?? fallbackName(for: bundleIdentifier),
                    bundlePath: exactProcess.bundlePath
                )
            }
        }

        if let owningApplication = runningApplications
            .filter({ application in
                guard application.isRegular,
                      let bundleIdentifier = application.bundleIdentifier else { return false }
                return process.bundleIdentifier == bundleIdentifier
                    || process.bundleIdentifier.hasPrefix(bundleIdentifier + ".")
            })
            .max(by: {
                ($0.bundleIdentifier?.count ?? 0) < ($1.bundleIdentifier?.count ?? 0)
            }),
           let bundleIdentifier = owningApplication.bundleIdentifier {
            return ApplicationIdentity(
                bundleIdentifier: bundleIdentifier,
                displayName: owningApplication.displayName ?? fallbackName(for: bundleIdentifier),
                bundlePath: owningApplication.bundlePath
            )
        }

        return ApplicationIdentity(
            bundleIdentifier: process.bundleIdentifier,
            displayName: fallbackName(for: process.bundleIdentifier),
            bundlePath: nil
        )
    }

    private static func owningRegularApplication(
        for helper: RunningApplicationRecord,
        among runningApplications: [RunningApplicationRecord]
    ) -> RunningApplicationRecord? {
        guard !helper.isRegular, let helperName = helper.displayName else { return nil }

        return runningApplications
            .filter { application in
                guard application.isRegular,
                      application.bundleIdentifier != nil,
                      let applicationName = application.displayName else { return false }
                return helperName == applicationName
                    || helperName.hasPrefix(applicationName + " ")
            }
            .max { left, right in
                (left.displayName?.count ?? 0) < (right.displayName?.count ?? 0)
            }
    }

    private static func outermostApplicationURL(_ url: URL?) -> URL? {
        guard let url else { return nil }
        let components = url.standardizedFileURL.pathComponents
        guard let appIndex = components.firstIndex(where: { $0.lowercased().hasSuffix(".app") }) else {
            return nil
        }
        return URL(fileURLWithPath: NSString.path(withComponents: Array(components[...appIndex])))
    }

    private static func fallbackName(for bundleIdentifier: String) -> String {
        bundleIdentifier.split(separator: ".").last.map(String.init) ?? bundleIdentifier
    }

    private static func stringProperty(
        _ objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }

    private static func pidProperty(_ objectID: AudioObjectID) -> pid_t? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = pid_t(0)
        var size = UInt32(MemoryLayout<pid_t>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    private static func uint32Property(
        _ objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }
}

struct AudioProcessRecord: Equatable, Sendable {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleIdentifier: String
    let isRunningOutput: Bool
}

struct RunningApplicationRecord: Equatable, Sendable {
    let pid: pid_t
    let processBundleIdentifier: String?
    let bundleIdentifier: String?
    let displayName: String?
    let bundlePath: String?
    let isRegular: Bool
}

private struct ApplicationIdentity {
    let bundleIdentifier: String
    let displayName: String
    let bundlePath: String?
}
