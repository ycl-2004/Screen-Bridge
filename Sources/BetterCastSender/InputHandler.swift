import Foundation
import CoreGraphics

final class InputHandler: @unchecked Sendable {
    static let shared = InputHandler()

    // Per-connection display bounds for multi-display routing
    private var displayBoundsMap: [UUID: CGRect] = [:]
    private let lock = NSLock()

    func updateDisplayBounds(bounds: CGRect, for connectionId: UUID) {
        lock.lock()
        displayBoundsMap[connectionId] = bounds
        lock.unlock()
        LogManager.shared.log("InputHandler: Updated bounds for connection \(connectionId.uuidString.prefix(8)): \(bounds)")
    }

    func removeDisplayBounds(for connectionId: UUID) {
        lock.lock()
        defer { lock.unlock() }
        displayBoundsMap.removeValue(forKey: connectionId)
    }

    func getDisplayBounds(for connectionId: UUID) -> CGRect {
        lock.lock()
        defer { lock.unlock() }
        return displayBoundsMap[connectionId] ?? .zero
    }

    func removeAllDisplayBounds() {
        lock.lock()
        defer { lock.unlock() }
        displayBoundsMap.removeAll()
    }
}
