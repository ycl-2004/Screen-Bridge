import Foundation

public enum PrivateBetterCastConstants {
    /// Version 3 adds sequence/sample timing metadata to every audio packet.
    /// Version 2 introduced connection roles and logical receiver sessions.
    public static let protocolVersion: UInt8 = 3
    public static let serviceType = "_yc-cast._tcp"
    public static let senderBundleID = "com.yichen.yccast.sender"
    public static let appGroupKeychainService = "com.yichen.yccast.pairing"
    public static let pairingSecretAccount = "pairing-secret-v1"
}
