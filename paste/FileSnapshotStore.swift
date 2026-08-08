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
