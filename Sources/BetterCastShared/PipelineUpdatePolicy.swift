import Foundation

public struct PipelineSettingsSnapshot: Equatable {
    public let useVirtualDisplay: Bool
    public let resolutionIdentifier: String
    public let usesRetinaBacking: Bool
    public let qualityBitrate: Int
    public let audioEnabled: Bool

    public init(
        useVirtualDisplay: Bool,
        resolutionIdentifier: String,
        usesRetinaBacking: Bool,
        qualityBitrate: Int,
        audioEnabled: Bool
    ) {
        self.useVirtualDisplay = useVirtualDisplay
        self.resolutionIdentifier = resolutionIdentifier
        self.usesRetinaBacking = usesRetinaBacking
        self.qualityBitrate = qualityBitrate
        self.audioEnabled = audioEnabled
    }
}

public enum PipelineUpdateAction: Hashable {
    case rebuildDisplay
    case updateBitrate
    case reconcileAudio
}

public enum PipelineUpdatePolicy {
    public static func actions(
        from applied: PipelineSettingsSnapshot,
        to requested: PipelineSettingsSnapshot
    ) -> Set<PipelineUpdateAction> {
        let displayChanged = applied.useVirtualDisplay != requested.useVirtualDisplay
            || applied.resolutionIdentifier != requested.resolutionIdentifier
            || applied.usesRetinaBacking != requested.usesRetinaBacking

        if displayChanged {
            // Rebuilding creates a fresh encoder and then reconciles audio, so
            // separate in-place actions would be redundant and racy.
            return [.rebuildDisplay]
        }

        var actions: Set<PipelineUpdateAction> = []
        if applied.qualityBitrate != requested.qualityBitrate {
            actions.insert(.updateBitrate)
        }
        if applied.audioEnabled != requested.audioEnabled {
            actions.insert(.reconcileAudio)
        }
        return actions
    }
}
