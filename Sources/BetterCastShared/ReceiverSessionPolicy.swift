import Foundation

public enum ReceiverSessionPolicy {
    /// Main media/control transports create or replace the logical session.
    /// Auxiliary transports are admitted only when they name the currently
    /// active session and that session still owns a main transport.
    public static func mayAttach(
        role: StreamConnectionRole,
        sessionID: UUID,
        activeSessionID: UUID?,
        hasMainTransport: Bool
    ) -> Bool {
        switch role {
        case .mediaControl:
            return true
        case .audio:
            return hasMainTransport && sessionID == activeSessionID
        }
    }
}
