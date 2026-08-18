#if canImport(UIKit)
import Foundation

private final class InputEventIDGenerator: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0

    func next() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        value &+= 1
        return value
    }
}

enum InputEventType: Int, Codable {
    case mouseMove = 0
    case leftMouseDown = 1
    case leftMouseUp = 2
    case rightMouseDown = 3
    case rightMouseUp = 4
    case keyDown = 5
    case keyUp = 6
    case scrollWheel = 7
    case command = 99 // Internal commands (e.g. Force Keyframe)
}

struct InputEvent: Codable {
    let type: InputEventType
    let x: Double // Normalized 0-1
    let y: Double // Normalized 0-1
    let keyCode: UInt16
    let deltaX: Double
    let deltaY: Double
    let eventId: UInt64

    private static let idGenerator = InputEventIDGenerator()

    init(type: InputEventType, x: Double = 0, y: Double = 0, keyCode: UInt16 = 0, deltaX: Double = 0, deltaY: Double = 0) {
        self.type = type
        self.x = x
        self.y = y
        self.keyCode = keyCode
        self.deltaX = deltaX
        self.deltaY = deltaY
        self.eventId = InputEvent.idGenerator.next()
    }
}
#endif
