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
            if cloneOrCopy(from: source, to: destination) {
                copiedURLs.append(destination)
            }
        }

        return copiedURLs
    }

    /// Snapshot `source` into `destination` as fast as possible.
    ///
    /// On APFS (every modern Mac's internal disk) `copyfile` with COPYFILE_CLONE
    /// makes a copy-on-write clone: near-instant regardless of size, even for a
    /// huge folder tree, yet still a fully independent snapshot that survives the
    /// original being changed or deleted. COPYFILE_CLONE already falls back to a
    /// real byte copy when cloning isn't possible (e.g. an external/non-APFS
    /// volume); if even that C path fails, we fall back to FileManager.
    private static func cloneOrCopy(from source: URL, to destination: URL) -> Bool {
        let flags = copyfile_flags_t(COPYFILE_CLONE | COPYFILE_RECURSIVE)
        let cloned = source.withUnsafeFileSystemRepresentation { src -> Int32 in
            guard let src else { return -1 }
            return destination.withUnsafeFileSystemRepresentation { dst -> Int32 in
                guard let dst else { return -1 }
                return copyfile(src, dst, nil, flags)
            }
        }
        if cloned == 0 { return true }
        // Last-resort fallback if the clone/copy syscall itself errored.
        do {
            try FileManager.default.copyItem(at: source, to: destination)
            return true
        } catch {
            return false
        }
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
