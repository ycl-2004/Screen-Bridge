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
    private let fileHandle: FileHandle? = {
        let directory = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Screen Bridge", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("sender.log")

        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return nil }
        // Truncate per launch: this is a diagnostic tail, not an audit trail.
        try? handle.truncate(atOffset: 0)
        return handle
    }()

    private let fileQueue = DispatchQueue(label: "com.yccast.logmanager.file")

    func log(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let line = "[\(timestamp)] \(message)"

        fileQueue.async { [weak self] in
            guard let handle = self?.fileHandle,
                  let data = (line + "\n").data(using: .utf8) else { return }
            try? handle.write(contentsOf: data)
        }

        DispatchQueue.main.async {
            self.logs.append(line)
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
            "Private pairing with optional Chrome audio",
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
