import AppKit
import Foundation

/// Temporary diagnostic log for the intermittent "popup disappears without
/// ⌘ being released and without pasting" report.
///
/// Writes to a plain file (~/Library/Application Support/Clipen/diag.log)
/// rather than only NSLog, because the failure is intermittent and needs to
/// be captured whenever it happens rather than while a console is attached.
/// Bounded so it can't grow without limit if left enabled.
///
/// Remove this file and its call sites once the cause is confirmed.
enum ClipenDiag {
    private static let queue = DispatchQueue(label: "com.clipen.diag")
    private static let maxBytes = 2 * 1024 * 1024

    static var logURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Clipen/diag.log")
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    /// Takes an already-built String rather than an @autoclosure: deferring
    /// evaluation would make every call site inside a closure require an
    /// explicit `self.`, which is noise for a temporary diagnostic.
    static func log(_ message: String) {
        let stamp = formatter.string(from: Date())
        queue.async {
            let line = "[\(stamp)] \(message)\n"
            let url = logURL
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                // Truncate wholesale rather than rotating — this is a
                // short-lived debugging aid, not a log system.
                if (try? handle.seekToEnd()).map({ $0 > UInt64(maxBytes) }) == true {
                    try? handle.truncate(atOffset: 0)
                    try? handle.seek(toOffset: 0)
                }
                try? handle.write(contentsOf: Data(line.utf8))
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
        NSLog("[ClipenDiag] %@", message)
    }
}
