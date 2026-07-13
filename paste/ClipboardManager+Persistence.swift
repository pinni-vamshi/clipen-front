import Foundation
import AppKit
import CryptoKit

private enum HistoryCrypto {
    static let keychainKey = "historyEncryptionKey"

    static var keyFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Clipen/history.key")
    }

    static let cachedKey: SymmetricKey = {
        if let data = try? Data(contentsOf: keyFileURL), data.count == 32 {
            return SymmetricKey(data: data)
        }
        Keychain.delete(keychainKey)
        let fresh = SymmetricKey(size: .bits256)
        writeKeyFile(fresh.withUnsafeBytes { Data($0) })
        return fresh
    }()

    static func writeKeyFile(_ data: Data) {
        let url = keyFileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic, .completeFileProtection])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: url.path)
    }

    static func encrypt(_ plaintext: Data) -> Data? {
        try? AES.GCM.seal(plaintext, using: cachedKey).combined
    }

    static func decrypt(_ ciphertext: Data) -> Data? {
        guard let box = try? AES.GCM.SealedBox(combined: ciphertext) else { return nil }
        return try? AES.GCM.open(box, using: cachedKey)
    }
}

extension ClipboardManager {

    func updateUserNote(id: UUID, note: String) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        if items[idx].userNote == nil && !note.isEmpty {
            AuthManager.shared.registerActionUsage(actionID: "ref.note_new")
        } else if items[idx].userNote != nil {
            AuthManager.shared.registerActionUsage(actionID: "ref.note_edit")
        }
        items[idx].userNote = note.isEmpty ? nil : note
        items[idx].embedding = nil
        lastSearchQuery = nil
        recomputeEmbeddingsInBackground()
    }

    static func editablePlainText(for item: ClipboardItem) -> String? {
        item.content.plainText
    }

    func updateItemText(id: UUID, newText: String) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        let old = items[idx]
        guard Self.editablePlainText(for: old) != nil,
              Self.editablePlainText(for: old) != newText else { return }
        replaceItemContent(id: id, newContent: .text(newText))
    }

    func updateItemTable(id: UUID, rows: [[String]]) {
        guard items.contains(where: { $0.id == id }) else { return }
        let cleanRows = rows.map { row in row.map { $0.replacingOccurrences(of: "\n", with: " ") } }
        func htmlRow(_ row: [String]) -> String {
            "<tr>" + row.map { "<td>\($0.htmlEscaped)</td>" }.joined() + "</tr>"
        }
        let html = "<table>" + cleanRows.map(htmlRow).joined() + "</table>"
        let plain = cleanRows.map { $0.joined(separator: "\t") }.joined(separator: "\n")
        replaceItemContent(id: id, newContent: .html(html, plain: plain))
    }

    func replaceItemContent(id: UUID, newContent: ClipboardContent) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        let old = items[idx]
        var updated = ClipboardItem(content: newContent, id: old.id,
                                    timestamp: old.timestamp,
                                    urlTitle: old.urlTitle,
                                    sourceAppName: old.sourceAppName)
        updated.isPinned          = old.isPinned
        updated.diffBadge         = old.diffBadge
        updated.sourceBundleID    = old.sourceBundleID
        updated.userNote          = old.userNote
        updated.pastedToAppName   = old.pastedToAppName
        updated.pastedToBundleID  = old.pastedToBundleID
        updated.lastPastedAt      = old.lastPastedAt
        updated.pasteCount        = old.pasteCount
        updated.pasteCountByApp   = old.pasteCountByApp
        updated.pastedToAppNames  = old.pastedToAppNames
        items[idx] = updated
        invalidateBlobCaches(for: id)
        lastSearchQuery = nil
        recomputeEmbeddingsInBackground()
    }

    func evictFileSnapshots(for item: ClipboardItem) {
        let urls: [URL]
        switch item.content {
        case .file(let u):   urls = [u]
        case .files(let us): urls = us
        default:             return
        }
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let snapshotBase = appSupport.appendingPathComponent("Clipen/FileCopies").path
        let dirs = Set(urls
            .filter { $0.path.hasPrefix(snapshotBase) }
            .map    { $0.deletingLastPathComponent() })
        for dir in dirs {
            try? FileManager.default.removeItem(at: dir)
        }
        for generatedBase in ["Clipen/Optimized", "Clipen/Converted"] {
            let basePath = appSupport.appendingPathComponent(generatedBase).path
            for url in urls where url.path.hasPrefix(basePath) {
                try? FileManager.default.removeItem(at: url)
                let parent = url.deletingLastPathComponent()
                if parent.path != basePath,
                   let contents = try? FileManager.default.contentsOfDirectory(atPath: parent.path),
                   contents.isEmpty {
                    try? FileManager.default.removeItem(at: parent)
                }
            }
        }
    }

    func togglePin(id: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        if items[idx].isPinned {
            items[idx].isPinned = false
            return
        }
        let pinnedCount = items.filter(\.isPinned).count
        guard pinnedCount < Self.maxPinnedItems else {
            flashStatus("Only \(Self.maxPinnedItems) items can be pinned at once.")
            return
        }
        items[idx].isPinned = true
        _displayItems = nil
    }

    func applyPinOrdering(_ list: [ClipboardItem]) -> [ClipboardItem] {
        guard list.contains(where: \.isPinned) else { return list }
        let pinned   = list.filter(\.isPinned)
        let unpinned = list.filter { !$0.isPinned }
        let leadingCount = min(max(0, pinStartPosition - 1), unpinned.count)
        var result = Array(unpinned.prefix(leadingCount))
        result.append(contentsOf: pinned)
        result.append(contentsOf: unpinned.dropFirst(leadingCount))
        return result
    }
    func removeItem(at index: Int) {
        guard items.indices.contains(index) else { return }
        evictFileSnapshots(for: items[index])
        items.remove(at: index)
        markBlobPurgeNeeded()
        if selectedIndex >= items.count { selectedIndex = max(0, items.count - 1) }
    }
    func clearAll() {
        items.forEach { evictFileSnapshots(for: $0) }
        items.removeAll()
        markBlobPurgeNeeded()
        selectedIndex = 0
    }

    func applyPlanLimits(ringLimit cap: Int) {
        let preferred = UserDefaults.standard.object(forKey: "preferredRingSize") as? Int
        let target = max(1, preferred.map { min($0, cap) } ?? 20)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.maxItems != target else { return }
            self.maxItems = target
        }
    }

    private struct PersistedItem: Codable {
        let id:        UUID
        let timestamp: Date
        let isPinned:  Bool
        let urlTitle:  String?
        let type:      String
        let text:      String?
        let imageData: Data?
        let imageBlob: String?
        let imageType: String?
        let rtfData:   Data?
        let plainText: String?
        let filePath:  String?
        let filePaths: [String]?
        let html:      String?
        let sourceAppName: String?
        let sourceBundleID: String?
        let embedding: [Float]?
        let pastedToAppName:  String?
        let pastedToBundleID: String?
        let lastPastedAt:     Date?
        let pasteCount:        Int?
        let pasteCountByApp:   [String: Int]?
        let pastedToAppNames:  [String: String]?
        var userNote: String? = nil
        var ocrText: String? = nil
        var sidecarBlob: String? = nil

        static func make(from item: ClipboardItem,
                         type: String,
                         text: String? = nil,
                         imageData: Data? = nil,
                         imageBlob: String? = nil,
                         imageType: String? = nil,
                         rtfData: Data? = nil,
                         plainText: String? = nil,
                         filePath: String? = nil,
                         filePaths: [String]? = nil,
                         html: String? = nil,
                         urlTitle: String? = nil) -> PersistedItem {
            PersistedItem(
                id: item.id, timestamp: item.timestamp, isPinned: item.isPinned,
                urlTitle: urlTitle, type: type, text: text,
                imageData: imageData, imageBlob: imageBlob, imageType: imageType,
                rtfData: rtfData, plainText: plainText, filePath: filePath,
                filePaths: filePaths, html: html,
                sourceAppName: item.sourceAppName, sourceBundleID: item.sourceBundleID,
                embedding: nil,
                pastedToAppName: item.pastedToAppName, pastedToBundleID: item.pastedToBundleID,
                lastPastedAt: item.lastPastedAt, pasteCount: item.pasteCount,
                pasteCountByApp: item.pasteCountByApp, pastedToAppNames: item.pastedToAppNames,
                userNote: item.userNote, ocrText: item.ocrText)
        }
    }

    var historyFileURL: URL {
        historyDir.appendingPathComponent("history.clip")
    }

    var embeddingsFileURL: URL {
        historyDir.appendingPathComponent("embeddings.clip")
    }

    func readEmbeddingsFile() -> [String: [Float]] {
        guard let cipher = try? Data(contentsOf: embeddingsFileURL),
              let plain  = HistoryCrypto.decrypt(cipher),
              let dict   = try? JSONDecoder().decode([String: [Float]].self, from: plain)
        else { return [:] }
        return dict
    }

    func saveEmbeddingsIfDirty(snapshot: [ClipboardItem]) {
        guard embeddingsDirty else { return }
        var dict: [String: [Float]] = [:]
        dict.reserveCapacity(snapshot.count)
        for item in snapshot {
            if let vec = item.embedding { dict[item.id.uuidString] = vec }
        }
        guard let plain  = try? JSONEncoder().encode(dict),
              let cipher = HistoryCrypto.encrypt(plain) else { return }
        do {
            try cipher.write(to: embeddingsFileURL, options: [.atomic, .completeFileProtection])
            embeddingsDirty = false
        } catch {
        }
    }

    var legacyPlaintextHistoryURL: URL {
        historyDir.appendingPathComponent("history.json")
    }

    var blobsDir: URL {
        historyDir.appendingPathComponent("blobs", isDirectory: true)
    }

    func reuseOrWriteBlob(cached: (path: String, bytes: Int)?,
                                  data: Data,
                                  primaryTag: ClipboardTag) -> String? {
        if let cached, cached.bytes == data.count,
           FileManager.default.fileExists(atPath: blobsDir.appendingPathComponent(cached.path).path) {
            return cached.path
        }
        return writeBlob(data, primaryTag: primaryTag)
    }

    func invalidateBlobCaches(for id: UUID) {
        saveQueue.async { [weak self] in
            self?.imageBlobCache[id] = nil
            self?.payloadBlobCache[id] = nil
            self?.sidecarBlobCache[id] = nil
            self?.blobPurgeNeeded = true
        }
    }

    func markBlobPurgeNeeded() {
        saveQueue.async { [weak self] in self?.blobPurgeNeeded = true }
    }

    func writeBlob(_ data: Data, primaryTag: ClipboardTag) -> String? {
        let tagDir = blobsDir.appendingPathComponent(primaryTag.folderName,
                                                     isDirectory: true)
        try? FileManager.default.createDirectory(at: tagDir, withIntermediateDirectories: true)
        let id = UUID().uuidString.lowercased()
        let fileURL = tagDir.appendingPathComponent("\(id).bin")
        guard let cipher = HistoryCrypto.encrypt(data) else { return nil }
        do {
            try cipher.write(to: fileURL, options: [.atomic, .completeFileProtection])
            return "\(primaryTag.folderName)/\(id).bin"
        } catch {
            return nil
        }
    }

    func readBlob(_ relativePath: String) -> Data? {
        let fileURL = blobsDir.appendingPathComponent(relativePath)
        guard let cipher = try? Data(contentsOf: fileURL),
              let plain  = HistoryCrypto.decrypt(cipher) else { return nil }
        return plain
    }

    func purgeOrphanBlobs(referenced: Set<String>) {
        guard let enumerator = FileManager.default.enumerator(
            at: blobsDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]) else { return }
        for case let url as URL in enumerator {
            guard let isFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile,
                  isFile else { continue }
            let parent = url.deletingLastPathComponent().lastPathComponent
            let name   = url.lastPathComponent
            let rel    = "\(parent)/\(name)"
            if !referenced.contains(rel) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    func saveHistory(snapshot: [ClipboardItem]? = nil) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        var referencedBlobs: Set<String> = []

        let itemsToSave = snapshot ?? items
        let persisted: [PersistedItem] = itemsToSave.compactMap { item in
            var p = persistedBase(for: item, referencedBlobs: &referencedBlobs)
            if p != nil, let sidecar = item.sidecarTypes {
                if let cached = sidecarBlobCache[item.id],
                   FileManager.default.fileExists(atPath: blobsDir.appendingPathComponent(cached).path) {
                    referencedBlobs.insert(cached)
                    p?.sidecarBlob = cached
                } else if let json = try? JSONEncoder().encode(sidecar),
                          let rel = writeBlob(json, primaryTag: item.primaryTag) {
                    sidecarBlobCache[item.id] = rel
                    referencedBlobs.insert(rel)
                    p?.sidecarBlob = rel
                }
            }
            return p
        }
        guard let plain = try? enc.encode(persisted),
              let cipher = HistoryCrypto.encrypt(plain) else { return }
        try? cipher.write(to: historyFileURL, options: [.atomic, .completeFileProtection])
        if historyLoadedCleanly, !itemsToSave.isEmpty {
            try? cipher.write(to: historyBackupURL, options: [.atomic, .completeFileProtection])
        }
        saveEmbeddingsIfDirty(snapshot: itemsToSave)
        if blobPurgeNeeded && historyLoadedCleanly {
            purgeOrphanBlobs(referenced: referencedBlobs)
            blobPurgeNeeded = false
        }
    }

    private func persistedBase(for item: ClipboardItem,
                               referencedBlobs: inout Set<String>) -> PersistedItem? {
            switch item.content {
            case .text(let str):
                return .make(from: item, type: "text", text: str, urlTitle: item.urlTitle)

            case .image(_, let rawData, let dataType):
                if let rel = reuseOrWriteBlob(cached: imageBlobCache[item.id],
                                              data: rawData,
                                              primaryTag: item.primaryTag) {
                    imageBlobCache[item.id] = (rel, rawData.count)
                    referencedBlobs.insert(rel)
                    return .make(from: item, type: "image", imageBlob: rel, imageType: dataType.rawValue)
                }
                guard rawData.count < Self.maxDataBytes else { return nil }
                return .make(from: item, type: "image", imageData: rawData, imageType: dataType.rawValue)

            case .richText(let attrStr, let plain):
                let range = NSRange(location: 0, length: attrStr.length)
                let rtf = try? attrStr.data(from: range,
                                            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
                return .make(from: item, type: "richText", rtfData: rtf, plainText: plain, urlTitle: item.urlTitle)

            case .html(let html, let plain):
                return .make(from: item, type: "html", plainText: plain, html: html, urlTitle: item.urlTitle)

            case .rtfd(let rtfdData, let plain):
                return .make(from: item, type: "rtfd", rtfData: rtfdData, plainText: plain, urlTitle: item.urlTitle)

            case .file(let url):
                return .make(from: item, type: "file", filePath: url.path)

            case .files(let urls):
                return .make(from: item, type: "files", filePaths: urls.map(\.path))

            case .svg(let src):
                return .make(from: item, type: "svg", text: src)

            case .blob(let typeMap):
                if let cached = payloadBlobCache[item.id],
                   FileManager.default.fileExists(atPath: blobsDir.appendingPathComponent(cached).path) {
                    referencedBlobs.insert(cached)
                    return .make(from: item, type: "blob", imageBlob: cached)
                }
                guard let jsonData = try? JSONEncoder().encode(typeMap),
                      let rel = writeBlob(jsonData, primaryTag: .blob) else { return nil }
                payloadBlobCache[item.id] = rel
                referencedBlobs.insert(rel)
                return .make(from: item, type: "blob", imageBlob: rel)
            }
    }

    var historyBackupURL: URL {
        historyDir.appendingPathComponent("history.clip.bak")
    }

    private func pruneQuarantineFiles(in dir: URL, keeping keep: Int) {
        guard let all = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let quarantines = all
            .filter { $0.lastPathComponent.hasPrefix("history.clip.corrupt-") }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return da > db
            }
        for stale in quarantines.dropFirst(keep) {
            try? FileManager.default.removeItem(at: stale)
        }
    }

    private func readManifest(at url: URL, dec: JSONDecoder) -> [PersistedItem]? {
        guard let cipher    = try? Data(contentsOf: url),
              let plain     = HistoryCrypto.decrypt(cipher),
              let persisted = try? dec.decode([PersistedItem].self, from: plain) else { return nil }
        return persisted
    }

    func loadHistory() {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601

        let primaryExisted = FileManager.default.fileExists(atPath: historyFileURL.path)

        var persisted = readManifest(at: historyFileURL, dec: dec)

        if persisted == nil, !primaryExisted,
           let legacy = try? Data(contentsOf: legacyPlaintextHistoryURL) {
            if let cipher = HistoryCrypto.encrypt(legacy) {
                try? cipher.write(to: historyFileURL, options: [.atomic, .completeFileProtection])
            }
            try? FileManager.default.removeItem(at: legacyPlaintextHistoryURL)
            persisted = try? dec.decode([PersistedItem].self, from: legacy)
        }

        if persisted == nil, primaryExisted {
            let stamp = Int(Date().timeIntervalSince1970)
            let quarantine = historyDir.appendingPathComponent("history.clip.corrupt-\(stamp)")
            try? FileManager.default.moveItem(at: historyFileURL, to: quarantine)
            pruneQuarantineFiles(in: historyDir, keeping: 3)
            NSLog("[Clipen] loadHistory: primary manifest unreadable — quarantined to \(quarantine.lastPathComponent), trying backup")
            if let fromBackup = readManifest(at: historyBackupURL, dec: dec) {
                persisted = fromBackup
                if let bakBytes = try? Data(contentsOf: historyBackupURL) {
                    try? bakBytes.write(to: historyFileURL, options: [.atomic, .completeFileProtection])
                }
                NSLog("[Clipen] loadHistory: restored \(fromBackup.count) items from history.clip.bak")
            }
        }

        guard let persisted else {
            historyLoadedCleanly = !primaryExisted
            return
        }
        historyLoadedCleanly = true
        if !persisted.isEmpty, let goodBytes = try? Data(contentsOf: historyFileURL) {
            try? goodBytes.write(to: historyBackupURL, options: [.atomic, .completeFileProtection])
        }
        var seedImage:   [UUID: (path: String, bytes: Int)] = [:]
        var seedPayload: [UUID: String] = [:]
        var seedSidecar: [UUID: String] = [:]
        let loadedEmbeddings = readEmbeddingsFile()
        var migratedInlineEmbedding = false
        let allLoaded = persisted.compactMap { p -> ClipboardItem? in
            let content: ClipboardContent
            switch p.type {
            case "text":
                guard let str = p.text else { return nil }
                content = .text(str)
            case "image":
                let raw: Data? = {
                    if let rel = p.imageBlob, let d = readBlob(rel) { return d }
                    return p.imageData
                }()
                guard let raw,
                      let imageContent = ClipboardContent.imageContent(
                          rawData: raw, dataType: .init(p.imageType ?? "public.png"),
                          fallback: NSImage(data: raw))
                else { return nil }
                if let rel = p.imageBlob { seedImage[p.id] = (rel, raw.count) }
                content = imageContent
            case "richText":
                guard let rtf = p.rtfData,
                      let attrStr = NSAttributedString(rtf: rtf, documentAttributes: nil) else { return nil }
                content = .richText(attrStr, plain: p.plainText ?? attrStr.string)
            case "html":
                guard let html = p.html else { return nil }
                content = .html(html, plain: p.plainText ?? "")
            case "rtfd":
                guard let rtfd = p.rtfData else { return nil }
                content = .rtfd(rtfd, plain: p.plainText ?? "")
            case "file":
                guard let path = p.filePath else { return nil }
                content = .file(URL(fileURLWithPath: path))
            case "files":
                guard let paths = p.filePaths, !paths.isEmpty else { return nil }
                content = .files(paths.map { URL(fileURLWithPath: $0) })
            case "svg":
                guard let str = p.text else { return nil }
                content = .svg(str)
            case "blob":
                guard let rel = p.imageBlob, let raw = readBlob(rel),
                      let typeMap = try? JSONDecoder().decode([String: Data].self, from: raw),
                      !typeMap.isEmpty else { return nil }
                seedPayload[p.id] = rel
                content = .blob(typeMap)
            default:
                return nil
            }
            var item = ClipboardItem(content: content, id: p.id, timestamp: p.timestamp,
                                     urlTitle: p.urlTitle, sourceAppName: p.sourceAppName,
                                     userNote: p.userNote, ocrText: p.ocrText)
            item.isPinned = p.isPinned
            item.sourceBundleID = p.sourceBundleID
            item.pastedToAppName  = p.pastedToAppName
            item.pastedToBundleID = p.pastedToBundleID
            item.lastPastedAt     = p.lastPastedAt
            item.pasteCount       = p.pasteCount ?? 0
            item.pasteCountByApp  = p.pasteCountByApp ?? [:]
            if let names = p.pastedToAppNames, !names.isEmpty {
                item.pastedToAppNames = names
            } else if let bid = p.pastedToBundleID, let name = p.pastedToAppName {
                item.pastedToAppNames = [bid: name]
            }
            if Self.persistedEmbeddingSchemaIsCurrent {
                if let fromDict = loadedEmbeddings[p.id.uuidString] {
                    item.embedding = fromDict
                } else if let inline = p.embedding {
                    item.embedding = inline
                    migratedInlineEmbedding = true
                }
            }
            if let rel = p.sidecarBlob, let raw = readBlob(rel),
               let sidecar = try? JSONDecoder().decode([String: Data].self, from: raw),
               !sidecar.isEmpty {
                item.sidecarTypes = sidecar
                seedSidecar[p.id] = rel
            }
            return item
        }
        let needsEmbeddingMigration = migratedInlineEmbedding
        saveQueue.async { [weak self] in
            guard let self else { return }
            self.imageBlobCache.merge(seedImage)     { _, new in new }
            self.payloadBlobCache.merge(seedPayload) { _, new in new }
            self.sidecarBlobCache.merge(seedSidecar) { _, new in new }
            if needsEmbeddingMigration { self.embeddingsDirty = true }
        }
        let pinned   = allLoaded.filter { $0.isPinned }
        let unpinned = allLoaded.filter { !$0.isPinned }
        items = pinned + unpinned
        embeddedItemCount = items.reduce(0) { $1.embedding == nil ? $0 : $0 + 1 }
        Self.markEmbeddingSchemaCurrent()
    }

    private static let embeddingSchemaVersion = 2
    private static let embeddingSchemaKey = "clipen.embeddingSchemaVersion"

    static var persistedEmbeddingSchemaIsCurrent: Bool {
        UserDefaults.standard.integer(forKey: embeddingSchemaKey) >= embeddingSchemaVersion
    }

    static func markEmbeddingSchemaCurrent() {
        UserDefaults.standard.set(embeddingSchemaVersion, forKey: embeddingSchemaKey)
    }

}
