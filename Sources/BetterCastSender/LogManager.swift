import SwiftUI

class LogManager: ObservableObject {
    static let shared = LogManager()
    @Published var logs: [String] = []

    /// Mirrors the in-app log to `~/Library/Logs/YC Cast/sender.log`.
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
            .appendingPathComponent("Library/Logs/YC Cast", isDirectory: true)
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

// MARK: - Update Checker

class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    /// Reads version from Info.plist (CFBundleShortVersionString), prefixed with "v"
    static var currentVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        // Extract major version number to match GitHub tag format (e.g., "8.0" → "v8")
        let major = short.components(separatedBy: ".").first ?? short
        return "v\(major)"
    }

    static var displayVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(short) (\(build))"
    }

    @Published var latestVersion: String?
    @Published var downloadURL: String?
    @Published var releaseNotes: String?
    @Published var updateAvailable = false
    @Published var checkedOnce = false

    /// Extracts the leading integer from a version tag like "v8", "V7", "v10.2" → 8, 7, 10
    static func versionNumber(from tag: String) -> Int {
        let digits = tag.drop(while: { !$0.isNumber })
        return Int(digits.prefix(while: { $0.isNumber })) ?? 0
    }

    func checkForUpdates() {
        checkedOnce = true
        updateAvailable = false
    }
}

// MARK: - Changelog

struct Changelog {
    struct Entry: Identifiable {
        let id = UUID()
        let version: String
        let date: String
        let highlights: [String]
    }

    static let entries: [Entry] = [
        Entry(version: UpdateChecker.currentVersion, date: "2026-05-11", highlights: [
            "iPad default display mode is Best Fit: 1344 x 934 HiDPI with native capture",
            "iPad receiver opens in Fit Screen mode and requires full screen",
            "Mac and iPad app icons are aligned for the private build",
            "Cleaner settings help tips with adjustable network mode, bitrate, Retina, and audio controls",
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
