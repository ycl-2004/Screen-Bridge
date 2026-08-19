import SwiftUI

final class LogManager: ObservableObject, @unchecked Sendable {
    static let shared = LogManager()
    @Published var logs: [String] = []

    /// Mirrors the in-app log to `~/Library/Logs/Screen Bridge/sender.log`.
    ///
    /// The in-memory buffer keeps only the last 200 lines and is lost when the
    /// app quits, and stdout is fully buffered when the app is launched by
    /// Launch Services — so neither survives the moment you actually need them.
    /// Streaming failures (display creation, pairing, capture) are exactly the
    /// ones you cannot reproduce on demand, so they get written to disk as they
    /// happen.
    ///
    /// A long-running session writes steadily (audio and send statistics report
    /// every few seconds), so the file is size-bounded rather than only
    /// truncated at launch: an app left connected for days would otherwise grow
    /// without limit. Rotation keeps one previous generation, so the window that
    /// actually explains a failure survives crossing the cap.
    private static let directory = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Screen Bridge", isDirectory: true)
    private static let logURL = directory.appendingPathComponent("sender.log")
    private static let previousLogURL = directory.appendingPathComponent("sender.log.1")
    private static let maximumLogBytes = 4 * 1_024 * 1_024

    /// Only ever touched on `fileQueue`.
    private var fileHandle: FileHandle?
    private var bytesWritten = 0

    private let fileQueue = DispatchQueue(label: "com.yccast.logmanager.file")

    /// Time-only for the in-app list, which never spans more than one session.
    private let displayTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
    /// The file can outlive a day of uptime, so its lines carry the date.
    private let fileTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    private init() {
        fileQueue.async { [weak self] in
            self?.openLogFile(truncating: true)
        }
    }

    /// Opens (and on launch truncates) the current log file. Must run on `fileQueue`.
    private func openLogFile(truncating: Bool) {
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let url = Self.logURL

        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(
                atPath: url.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            )
        }
        // Tighten files created by older builds that inherited the umask
        // (typically 0644 — world-readable network topology diagnostics).
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)

        guard let handle = try? FileHandle(forWritingTo: url) else {
            fileHandle = nil
            return
        }
        if truncating {
            try? handle.truncate(atOffset: 0)
            bytesWritten = 0
        } else {
            bytesWritten = Int((try? handle.seekToEnd()) ?? 0)
        }
        fileHandle = handle
    }

    /// Must run on `fileQueue`.
    private func rotateIfNeeded(adding byteCount: Int) {
        guard bytesWritten + byteCount > Self.maximumLogBytes else { return }
        try? fileHandle?.close()
        fileHandle = nil
        try? FileManager.default.removeItem(at: Self.previousLogURL)
        try? FileManager.default.moveItem(at: Self.logURL, to: Self.previousLogURL)
        openLogFile(truncating: true)
    }

    func log(_ message: String) {
        let now = Date()
        let displayLine = "[\(displayTimestampFormatter.string(from: now))] \(message)"
        let fileLine = "[\(fileTimestampFormatter.string(from: now))] \(message)\n"

        fileQueue.async { [weak self] in
            guard let self, let data = fileLine.data(using: .utf8) else { return }
            self.rotateIfNeeded(adding: data.count)
            guard let handle = self.fileHandle else { return }
            try? handle.write(contentsOf: data)
            self.bytesWritten += data.count
        }

        DispatchQueue.main.async {
            self.logs.append(displayLine)
            if self.logs.count > 200 {
                self.logs.removeFirst()
            }
            print(message)
        }
    }
}

// MARK: - App Version

/// Public release identity shown in the settings UI.
///
/// Internal self-built bundle numbers may advance while the product is still
/// preparing its first public release, so the user-facing release stays v1.
enum AppVersion {
    static let current = "v1"
}

// MARK: - Changelog

struct Changelog {
    struct Entry: Identifiable {
        let id = UUID()
        let version: String
        let highlights: [String]
    }

    static let entries: [Entry] = [
        Entry(version: AppVersion.current, highlights: [
            "Extended or mirrored display streaming",
            "Private pairing with per-app audio routing",
        ]),
    ]
}

// MARK: - Log View

struct LogView: View {
    @ObservedObject var logManager = LogManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Action buttons
            HStack {
                Spacer()

                Button {
                    let text = logManager.logs.joined(separator: "\n")
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(text, forType: .string)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    logManager.logs.removeAll()
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 6)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(logManager.logs, id: \.self) { log in
                        Text(log)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Logs")
    }
}
