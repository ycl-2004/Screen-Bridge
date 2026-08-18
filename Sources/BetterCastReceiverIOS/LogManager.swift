#if canImport(UIKit)
import Foundation

/// Thread-safe receiver diagnostics persisted in the app's Documents directory.
/// The file is intentionally bounded and contains transport metadata only.
final class LogManager: @unchecked Sendable {
    static let shared = LogManager()

    private let lock = NSLock()
    private let maximumLogBytes: UInt64 = 2 * 1_024 * 1_024
    let logFileURL: URL

    private init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        logFileURL = documents.appendingPathComponent("Screen Bridge-Receiver-Diagnostics.log")
    }

    func log(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        print(line, terminator: "")

        guard let data = line.data(using: .utf8) else { return }
        lock.lock()
        defer { lock.unlock() }

        rotateIfNeeded(adding: data.count)
        if !FileManager.default.fileExists(atPath: logFileURL.path) {
            FileManager.default.createFile(atPath: logFileURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: logFileURL) else { return }
        handle.seekToEndOfFile()
        handle.write(data)
        handle.closeFile()
    }

    func exportURL() -> URL? {
        lock.lock()
        defer { lock.unlock() }
        return FileManager.default.fileExists(atPath: logFileURL.path) ? logFileURL : nil
    }

    private func rotateIfNeeded(adding byteCount: Int) {
        let currentSize = ((try? FileManager.default.attributesOfItem(atPath: logFileURL.path)[.size]) as? NSNumber)?.uint64Value ?? 0
        guard currentSize + UInt64(byteCount) > maximumLogBytes else { return }
        try? FileManager.default.removeItem(at: logFileURL)
    }
}
#endif
