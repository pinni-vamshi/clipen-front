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

    static var baseDirectory: URL {
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

    // MARK: Identity

    /// What makes two copies "the same files": name, size and modification
    /// time of each — of every entry inside, for a folder. A snapshot keeps
    /// all three (clones and copies preserve modification times), so the
    /// source being copied can be matched against snapshots already taken
    /// without reading a byte of content. Editing anything changes it.
    ///
    /// nil means "don't know" (unreadable, or a folder too large to walk
    /// cheaply) and never matches anything.
    nonisolated static func identity(of urls: [URL]) -> [String]? {
        var parts: [String] = []
        for url in urls {
            guard let part = identity(of: url) else { return nil }
            parts.append(part)
        }
        return parts.isEmpty ? nil : parts
    }

    nonisolated private static let identityLock = NSLock()
    nonisolated(unsafe) private static var identityCache: [String: String] = [:]

    nonisolated private static func identity(of url: URL) -> String? {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        guard let values = try? url.resourceValues(forKeys: keys),
              let modified = values.contentModificationDate else { return nil }
        let name = url.lastPathComponent
        guard values.isDirectory == true else {
            return "\(name)|\(values.fileSize ?? -1)|\(modified.timeIntervalSince1970)"
        }
        // Folder walks are cached per path + modification date. Snapshot
        // folders never change, so each is walked once per session.
        let cacheKey = "\(url.path)|\(modified.timeIntervalSince1970)"
        identityLock.lock()
        if let cached = identityCache[cacheKey] { identityLock.unlock(); return cached }
        identityLock.unlock()

        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys)) else { return nil }
        var count = 0
        var bytes = 0
        var newest = modified.timeIntervalSince1970
        for case let entry as URL in walker {
            count += 1
            if count > 20_000 { return nil }
            guard let v = try? entry.resourceValues(forKeys: keys) else { return nil }
            bytes += v.fileSize ?? 0
            newest = max(newest, v.contentModificationDate?.timeIntervalSince1970 ?? 0)
        }
        let identity = "\(name)/|\(count)|\(bytes)|\(newest)"
        identityLock.lock()
        identityCache[cacheKey] = identity
        identityLock.unlock()
        return identity
    }
}
