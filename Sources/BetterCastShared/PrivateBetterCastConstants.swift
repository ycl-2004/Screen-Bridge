import Foundation

public enum PrivateBetterCastConstants {
    /// Version 2 adds an explicit connection role, a logical receiver session,
    /// and receiver display capabilities to the authenticated handshake.
    public static let protocolVersion: UInt8 = 2
    public static let serviceType = "_yc-cast._tcp"
    public static let senderBundleID = "com.yichen.yccast.sender"
    public static let receiverBundleID = "com.yichen.yccast.receiver.ios"
    public static let appGroupKeychainService = "com.yichen.yccast.pairing"
    public static let pairingSecretAccount = "pairing-secret-v1"
}
