import Foundation

public enum PrivateBetterCastConstants {
    /// Version 4 seals sender→receiver control messages (heartbeat, disconnect
    /// notice) inside authenticated envelopes under type byte 0x05, and adds a
    /// version field to ReceiverHello so both directions of the handshake
    /// enforce the same protocol. Version 3 added sequence/sample timing
    /// metadata to every audio packet; version 2 introduced connection roles
    /// and logical receiver sessions.
    public static let protocolVersion: UInt8 = 4
    public static let serviceType = "_yc-cast._tcp"
    public static let senderBundleID = "com.yichen.yccast.sender"
    public static let appGroupKeychainService = "com.yichen.yccast.pairing"
    public static let pairingSecretAccount = "pairing-secret-v1"
}
