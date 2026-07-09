import Foundation

enum FileSnapshotStore {
    static func snapshot(_ urls: [URL]) -> [URL] {
        guard !urls.isEmpty else { return [] }

        let fileManager = FileManager.default
        let groupDirectory = baseDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        do {
            try fileManager.createDirectory(at: groupDirectory, withIntermediateDirectories: true)
        } catch {
            return urls
        }

        var copiedURLs: [URL] = []
        copiedURLs.reserveCapacity(urls.count)

        for source in urls {
            let destination = uniqueDestination(for: source, in: groupDirectory)
            do {
                try fileManager.copyItem(at: source, to: destination)
                copiedURLs.append(destination)
            } catch {
                // Drop it rather than falling back to the original URL.
                // That fallback used to silently persist a reference to
                // whatever couldn't be copied — harmless for an ordinary
                // local file, but a landmine for a transient path (Universal
                // Clipboard / Continuity staging files, promised-file temp
                // dirs): those get cleaned up by the OS later, so the "copy"
                // Clipen kept was really just a dead path that broke the
                // moment you tried to use it. A capture that couldn't be
                // copied cleanly shouldn't be preserved at all.
            }
        }

        return copiedURLs
    }

    private static var baseDirectory: URL {
        let directory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Clipen/FileCopies", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func uniqueDestination(for source: URL, in directory: URL) -> URL {
        let fileManager = FileManager.default
        let originalName = source.lastPathComponent.isEmpty ? "Copied File" : source.lastPathComponent
        let baseName = (originalName as NSString).deletingPathExtension
        let ext = (originalName as NSString).pathExtension
        var candidate = directory.appendingPathComponent(originalName)
        var suffix = 2

        while fileManager.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(baseName) \(suffix)" : "\(baseName) \(suffix).\(ext)"
            candidate = directory.appendingPathComponent(name)
            suffix += 1
        }

        return candidate
    }
}
