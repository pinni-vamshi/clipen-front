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
        CloudKitSyncEngine.shared.pushUpdate(items[idx])
    }

    static func editableAttributedString(for item: ClipboardItem) -> NSAttributedString? {
        switch item.content {
        case .richText(let attr, _):
            return attr
        case .rtfd(let data, _):
            return NSAttributedString(rtfd: data, documentAttributes: nil)
        case .html(let html, _):
            guard let data = html.data(using: .utf8) else { return nil }
            return NSAttributedString(html: data, documentAttributes: nil)
        default:
            return nil
        }
    }

    static func editablePlainText(for item: ClipboardItem) -> String? {
        // A copied file (.txt, .html, .md, .json, .csv, code files, …) is
        // stored as a URL, not a string — but it's always Clipen's OWN private
        // snapshot copy (FileSnapshotStore clones it before it ever becomes a
        // ClipboardItem), never the user's original file elsewhere on disk, so
        // reading — and later overwriting — it is safe. Binary-ish "text-like"
        // formats (.webarchive) are deliberately excluded via isTextFile.
        if case .file(let url) = item.content, FileKindDetector.isTextFile(url) {
            return try? String(contentsOf: url, encoding: .utf8)
        }
        return item.content.plainText
    }

    /// Commits an edit to a file-backed item (see `editablePlainText` above)
    /// by overwriting Clipen's own snapshot copy in place. The item's content
    /// stays `.file(url)` — only the bytes at that path change — so every
    /// preview surface just needs to re-read the same URL, which the existing
    /// hide()-then-reshow on every edit commit already forces.
    func updateFileItemText(id: UUID, newText: String) {
        guard let idx = items.firstIndex(where: { $0.id == id }),
              case .file(let url) = items[idx].content,
              FileKindDetector.isTextFile(url) else { return }

        if items[idx].originalFileURL == nil {
            // FIRST edit — never touch the original. Preserve it exactly where
            // it is and write the edit to a NEW sibling file, then point the
            // item at that edited copy. "Revert to Original" can later throw
            // the edit away and bring the original back.
            let original = url
            guard (try? String(contentsOf: original, encoding: .utf8)) != newText else { return }
            let stem = original.deletingPathExtension().lastPathComponent
            let ext  = original.pathExtension
            let editedName = ext.isEmpty ? "\(stem)-edited" : "\(stem)-edited.\(ext)"
            let editedURL = original.deletingLastPathComponent().appendingPathComponent(editedName)
            do {
                try newText.write(to: editedURL, atomically: true, encoding: .utf8)
            } catch {
                flashStatus("Couldn't save the edit.")
                return
            }
            replaceItemContent(id: id, newContent: .file(editedURL))
            if let i = items.firstIndex(where: { $0.id == id }) {
                items[i].originalFileURL = original
            }
        } else {
            // RE-EDIT — `url` is already the edited copy; overwrite just it and
            // leave the original untouched.
            guard (try? String(contentsOf: url, encoding: .utf8)) != newText else { return }
            do {
                try newText.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                flashStatus("Couldn't save the edit.")
                return
            }
            invalidateBlobCaches(for: id)
            lastSearchQuery = nil
            recomputeEmbeddingsInBackground()
        }
    }

    /// "Revert to Original" — throw away a file edit: delete the edited copy on
    /// disk and point the item back at its preserved original. No-op on any
    /// item that isn't an edited file.
    func revertFileEdit(id: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == id }),
              let original = items[idx].originalFileURL,
              case .file(let editedURL) = items[idx].content else { return }
        if editedURL != original {
            try? FileManager.default.removeItem(at: editedURL)
        }
        replaceItemContent(id: id, newContent: .file(original))
        if let i = items.firstIndex(where: { $0.id == id }) {
            items[i].originalFileURL = nil
        }
        ToolRegistry.invalidateCache()
        flashStatus("Reverted to original.")
    }

    func updateItemText(id: UUID, newText: String) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        let old = items[idx]
        guard Self.editablePlainText(for: old) != nil,
              Self.editablePlainText(for: old) != newText else { return }
        // Rich content must survive the edit as rich content — otherwise the
        // "Paste with Formatting" transform quietly disappears from every
        // item the user has ever edited. Re-serialize the new plain string
        // into the SAME container the original used, carrying the original's
        // dominant character attributes forward.
        replaceItemContent(id: id, newContent: Self.reboundEditedContent(old: old.content, newText: newText))
    }

    /// Splice `newText` into the container of `old`, preserving the original's
    /// formatting (font, color, paragraph attributes) as best-effort. Falls
    /// back to plain text if the original had no rich container to keep.
    private static func reboundEditedContent(old: ClipboardContent, newText: String) -> ClipboardContent {
        switch old {
        case .richText(let attr, plain: _):
            let mutable = NSMutableAttributedString(attributedString: attr)
            if mutable.length == 0 {
                return .text(newText)
            }
            // Replace the entire body — NSAttributedString extends the leading
            // attribute run across the new string, keeping font/color/etc.
            mutable.replaceCharacters(in: NSRange(location: 0, length: mutable.length), with: newText)
            return .richText(NSAttributedString(attributedString: mutable), plain: newText)

        case .rtfd(let data, plain: _):
            var docAttrs: NSDictionary?
            guard let attr = NSAttributedString(
                    rtfd: data,
                    documentAttributes: &docAttrs) ?? NSAttributedString(
                    rtf: data,
                    documentAttributes: &docAttrs)
            else { return .text(newText) }
            let mutable = NSMutableAttributedString(attributedString: attr)
            if mutable.length == 0 { return .text(newText) }
            mutable.replaceCharacters(in: NSRange(location: 0, length: mutable.length), with: newText)
            let attrs = (docAttrs as? [NSAttributedString.DocumentAttributeKey: Any]) ?? [
                .documentType: NSAttributedString.DocumentType.rtfd
            ]
            if let newData = try? mutable.data(
                from: NSRange(location: 0, length: mutable.length),
                documentAttributes: attrs) {
                return .rtfd(newData, plain: newText)
            }
            return .text(newText)

        case .html(_, plain: _):
            // HTML edits are rare enough (Notes copies etc.) that a minimal
            // wrapper preserves the "this is HTML" identity — enough for the
            // Paste with Formatting tool to keep surfacing.
            let escaped = newText.htmlEscaped
            let html = "<p>" + escaped.replacingOccurrences(of: "\n", with: "<br>") + "</p>"
            return .html(html, plain: newText)

        default:
            return .text(newText)
        }
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
        // Otherwise re-editing this item would show the stale pre-edit cells —
        // TableCellExtractor's cache is keyed by item id, which doesn't change.
        TableCellExtractor.invalidate(itemID: id)
    }

    func updateItemRichText(id: UUID, editedAttributedString attr: NSAttributedString) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        let plain = attr.string
        let newContent: ClipboardContent
        let range = NSRange(location: 0, length: attr.length)
        switch items[idx].content {
        case .rtfd:
            if let data = try? attr.data(from: range,
                                         documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]) {
                newContent = .rtfd(data, plain: plain)
            } else {
                newContent = .richText(NSAttributedString(attributedString: attr), plain: plain)
            }
        case .html:
            if let data = try? attr.data(from: range,
                                         documentAttributes: [.documentType: NSAttributedString.DocumentType.html]),
               let html = String(data: data, encoding: .utf8) {
                newContent = .html(html, plain: plain)
            } else {
                newContent = .richText(NSAttributedString(attributedString: attr), plain: plain)
            }
        default:
            newContent = .richText(NSAttributedString(attributedString: attr), plain: plain)
        }
        replaceItemContent(id: id, newContent: newContent)
    }

    func updateItemMixed(id: UUID, segments: [ContentSegment]) {
        guard items.contains(where: { $0.id == id }) else { return }
        var htmlParts: [String] = []
        var plainParts: [String] = []
        for seg in segments {
            switch seg {
            case .text(let text):
                let escaped = text.htmlEscaped
                htmlParts.append("<p>" + escaped.replacingOccurrences(of: "\n", with: "<br>") + "</p>")
                plainParts.append(text)
            case .table(let rows):
                let clean = rows.map { $0.map { $0.replacingOccurrences(of: "\n", with: " ") } }
                func htmlRow(_ row: [String]) -> String {
                    "<tr>" + row.map { "<td>\($0.htmlEscaped)</td>" }.joined() + "</tr>"
                }
                htmlParts.append("<table>" + clean.map(htmlRow).joined() + "</table>")
                plainParts.append(clean.map { $0.joined(separator: "\t") }.joined(separator: "\n"))
            }
        }
        let html = htmlParts.joined()
        let plain = plainParts.joined(separator: "\n\n")
        replaceItemContent(id: id, newContent: .html(html, plain: plain))
        TableCellExtractor.invalidate(itemID: id)
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
        updated.originalFileURL   = old.originalFileURL
        items[idx] = updated
        invalidateBlobCaches(for: id)
        lastSearchQuery = nil
        recomputeEmbeddingsInBackground()
        prewarmPreviewCaches(for: updated)
        CloudKitSyncEngine.shared.pushUpdate(updated)
    }

    func evictFileSnapshots(for item: ClipboardItem) {
        var urls: [URL]
        switch item.content {
        case .file(let u):   urls = [u]
        case .files(let us): urls = us
        default:             return
        }
        // An edited file item also has a preserved original alongside it —
        // clean both up (they're normally siblings, so removing either's parent
        // dir already gets both, but include it explicitly to be safe).
        if let original = item.originalFileURL { urls.append(original) }
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
            CloudKitSyncEngine.shared.pushUpdate(items[idx])
            return
        }
        let pinnedCount = items.filter(\.isPinned).count
        guard pinnedCount < Self.maxPinnedItems else {
            flashStatus("Only \(Self.maxPinnedItems) items can be pinned at once.")
            return
        }
        items[idx].isPinned = true
        CloudKitSyncEngine.shared.pushUpdate(items[idx])
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
        let item = items[index]
        CloudKitSyncEngine.shared.pushDelete(itemID: item.id)
        evictFileSnapshots(for: item)
        evictCaches(for: item.id)
        items.remove(at: index)
        markBlobPurgeNeeded()
        if selectedIndex >= items.count { selectedIndex = max(0, items.count - 1) }
    }
    func clearAll() {
        let ids = items.map(\.id)
        items.forEach {
            evictFileSnapshots(for: $0)
            evictCaches(for: $0.id)
        }
        items.removeAll()
        markBlobPurgeNeeded()
        selectedIndex = 0
        for id in ids {
            CloudKitSyncEngine.shared.pushDelete(itemID: id)
        }
    }

    func evictCaches(for id: UUID) {
        TableCellExtractor.invalidate(itemID: id)
        EmbeddedImageExtractor.invalidate(itemID: id)
        ImageSimilarityService.invalidate(itemID: id)
        inlineEditOriginals.removeValue(forKey: id)
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
        // Members of a ⌘+G group, persisted recursively (a struct array of
        // itself is fine for Codable — no `indirect` needed).
        var groupChildren: [PersistedItem]? = nil
        // User-defined collections this clip belongs to (multi-membership).
        var collections: [String]? = nil
        // Set only on an edited file item — the preserved original alongside
        // the edited copy (`filePath`). Optional-with-default so older
        // manifests without this key still decode cleanly (no false quarantine).
        var originalFilePath: String? = nil

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
                         urlTitle: String? = nil,
                         groupChildren: [PersistedItem]? = nil) -> PersistedItem {
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
                userNote: item.userNote, ocrText: item.ocrText,
                groupChildren: groupChildren,
                collections: item.collections.isEmpty ? nil : Array(item.collections),
                originalFilePath: item.originalFileURL?.path)
        }
    }

    var historyFileURL: URL {
        historyDir.appendingPathComponent("history.clip")
    }

    /// Tiny sidecar holding just the first-screen items (the same selection
    /// the loader prioritizes). Written on every save; read FIRST on launch so
    /// the window paints real, usable items in O(45) instead of waiting for the
    /// whole encrypted manifest — with every inline RTF blob — to decode.
    var historyHeadURL: URL {
        historyDir.appendingPathComponent("history.head.clip")
    }

    /// How many unpinned items ride in the priority/head batch (pinned items
    /// are always included on top of this). Save and load MUST use the same
    /// selection so the head paint and the full load's priority publish share
    /// identical ids/order — that's what makes the hand-off flash-free.
    static let historyPriorityUnpinnedCount = 40

    private static func historyPrioritySlice(_ items: [PersistedItem]) -> [PersistedItem] {
        items.filter(\.isPinned)
            + items.filter { !$0.isPinned }.prefix(historyPriorityUnpinnedCount)
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
        // An edit reuses the same item.id with new content — the RTFD preview
        // cache keyed on that id must drop its stale decoded/adjusted string
        // or an edited item would keep showing its pre-edit rendering.
        AdjustedAttrCache.shared.invalidate(itemID: id)
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
        // While the async load is still filling in `items` (head-paint batch,
        // then the priority batch, then background chunks — see
        // isHistoryFullyLoaded's doc comment), `items` is only a PARTIAL view
        // of the real history. Saving here — from ANY call site, not just the
        // debounced auto-save — would silently overwrite the real encrypted
        // history on disk with that partial slice. Once the load finishes it
        // republishes `items`, which reschedules the debounced save and any
        // callers that skipped saving here can simply call it again.
        guard snapshot != nil || isHistoryFullyLoaded else { return }
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
        // Refresh the instant-paint head sidecar from the same snapshot, using
        // the exact same priority selection the loader will use. Its blobs are
        // a subset of `referencedBlobs` above, so they're never purged out from
        // under it.
        let head = Self.historyPrioritySlice(persisted)
        if let headPlain = try? enc.encode(head),
           let headCipher = HistoryCrypto.encrypt(headPlain) {
            try? headCipher.write(to: historyHeadURL, options: [.atomic, .completeFileProtection])
        }
        saveEmbeddingsIfDirty(snapshot: itemsToSave)
        if blobPurgeNeeded && historyLoadedCleanly {
            purgeOrphanBlobs(referenced: referencedBlobs)
            blobPurgeNeeded = false
        }
    }

    /// Reconstruct a persisted item's content, recursing into group members.
    /// Group children read their blobs inline and are intentionally not seeded
    /// into the top-level blob caches (they're re-referenced on the next save).
    private func decodeContent(_ p: PersistedItem) -> ClipboardContent? {
        switch p.type {
        case "text":  return p.text.map { .text($0) }
        case "svg":   return p.text.map { .svg($0) }
        case "html":  return p.html.map { .html($0, plain: p.plainText ?? "") }
        case "rtfd":  return p.rtfData.map { .rtfd($0, plain: p.plainText ?? "") }
        case "file":  return p.filePath.map { .file(URL(fileURLWithPath: $0)) }
        case "files":
            guard let paths = p.filePaths, !paths.isEmpty else { return nil }
            return .files(paths.map { URL(fileURLWithPath: $0) })
        case "image":
            let raw: Data? = { if let rel = p.imageBlob, let d = readBlob(rel) { return d }; return p.imageData }()
            guard let raw else { return nil }
            return ClipboardContent.imageContent(rawData: raw,
                                                 dataType: .init(p.imageType ?? "public.png"),
                                                 fallback: NSImage(data: raw))
        case "richText":
            guard let rtf = p.rtfData, let a = NSAttributedString(rtf: rtf, documentAttributes: nil) else { return nil }
            return .richText(a, plain: p.plainText ?? a.string)
        case "blob":
            guard let rel = p.imageBlob, let raw = readBlob(rel),
                  let m = try? JSONDecoder().decode([String: Data].self, from: raw), !m.isEmpty else { return nil }
            return .blob(m)
        case "group":
            guard let kids = p.groupChildren else { return nil }
            let items = kids.prefix(Self.maxGroupItems).compactMap { child -> ClipboardItem? in
                guard let c = decodeContent(child) else { return nil }
                return ClipboardItem(content: c, id: child.id, timestamp: child.timestamp,
                                     urlTitle: child.urlTitle, sourceAppName: child.sourceAppName,
                                     userNote: child.userNote, ocrText: child.ocrText)
            }
            return items.isEmpty ? nil : .group(Array(items))
        default:
            return nil
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

            case .group(let items):
                // Persist each member recursively (their image blobs get written
                // and marked referenced through the same inout set, so they're
                // never purged while the group lives).
                let children = items.compactMap {
                    persistedBase(for: $0, referencedBlobs: &referencedBlobs)
                }
                guard !children.isEmpty else { return nil }
                return .make(from: item, type: "group", groupChildren: children)
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

    /// Scans `history.clip.corrupt-*` quarantine files and, if one decodes
    /// cleanly against the current schema and holds MORE items than what we
    /// currently have, merges it back into `current` (deduped by id, newest
    /// first, capped to the user's ring size), persists the result, and
    /// returns it. Each quarantine file is attempted at most once ever, so on
    /// a normal launch (no quarantine files) this is an immediate no-op.
    /// Returns nil when there's nothing better to recover.
    private func recoverFromQuarantineIfBetter(current: [PersistedItem],
                                               dec: JSONDecoder) -> [PersistedItem]? {
        let attemptedKey = "clipen.recoveryAttemptedQuarantines"
        let d = UserDefaults.standard
        var attempted = Set(d.stringArray(forKey: attemptedKey) ?? [])

        guard let files = try? FileManager.default.contentsOfDirectory(
                at: historyDir, includingPropertiesForKeys: nil) else { return nil }
        let candidates = files.filter {
            $0.lastPathComponent.hasPrefix("history.clip.corrupt-")
                && !attempted.contains($0.lastPathComponent)
        }
        guard !candidates.isEmpty else { return nil }

        // Pick the quarantine file that decodes cleanly and holds the most.
        var best: [PersistedItem] = []
        for f in candidates {
            attempted.insert(f.lastPathComponent)
            if let items = readManifest(at: f, dec: dec), items.count > best.count {
                best = items
            }
        }

        // Only worth recovering if a quarantine genuinely has MORE than now.
        guard best.count > current.count else {
            d.set(Array(attempted), forKey: attemptedKey)
            return nil
        }

        // Merge: keep everything current (it's newer) ahead of recovered items
        // not already present — deduped by id so nothing is duplicated.
        let currentIDs = Set(current.map(\.id))
        let merged = current + best.filter { !currentIDs.contains($0.id) }

        // Respect the user's ring size: keep all pinned + the newest N unpinned
        // (same rule normal eviction uses), preserving order. Read the size
        // straight from defaults — self.maxItems may not be applied yet this
        // early in launch. 500 is the hard plan cap.
        let ringSize = min(max(1, d.object(forKey: "preferredRingSize") as? Int ?? 20), 500)
        var capped: [PersistedItem] = []
        var unpinnedKept = 0
        for item in merged {
            if item.isPinned {
                capped.append(item)
            } else if unpinnedKept < ringSize {
                capped.append(item); unpinnedKept += 1
            }
        }

        // Persist the recovery to disk IMMEDIATELY (before marking the sources
        // attempted) so it survives even an instant quit — never lose the
        // recovery to a crash between restoring and the normal post-load save.
        // The originating `history.clip.corrupt-*` file is left untouched on
        // disk, so the older items beyond the ring size stay retrievable.
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let plain = try? enc.encode(capped),
              let cipher = HistoryCrypto.encrypt(plain) else { return nil }
        try? cipher.write(to: historyFileURL, options: [.atomic, .completeFileProtection])
        try? cipher.write(to: historyBackupURL, options: [.atomic, .completeFileProtection])
        d.set(Array(attempted), forKey: attemptedKey)
        NSLog("[Clipen] loadHistory: auto-recovered \(capped.count) items from quarantine (previously had \(current.count))")
        return capped
    }

    /// Kicks off history load in the background. The app was freezing 1-20 s
    /// on launch because the manifest read + decrypt + JSON decode + N per-
    /// item blob reads all ran on the main thread. The window can now open
    /// with an empty ring immediately; items populate a beat later.
    func loadHistory() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.performHistoryLoadOffMain()
        }
    }

    private struct HistoryDecodedBatch {
        let items: [ClipboardItem]
        let seedImage:   [UUID: (path: String, bytes: Int)]
        let seedPayload: [UUID: String]
        let seedSidecar: [UUID: String]
        let migratedInlineEmbedding: Bool
    }

    /// Turns persisted rows into live `ClipboardItem`s. This is the per-item
    /// expensive part — image bitmap decode, RTF/RTFD parse, per-blob decrypt —
    /// so callers run it on a background queue and keep each batch small.
    private func decodeHistoryBatch(_ batch: [PersistedItem],
                                    loadedEmbeddings: [String: [Float]]) -> HistoryDecodedBatch {
        var seedImage:   [UUID: (path: String, bytes: Int)] = [:]
        var seedPayload: [UUID: String] = [:]
        var seedSidecar: [UUID: String] = [:]
        var migratedInlineEmbedding = false
        let loaded = batch.compactMap { p -> ClipboardItem? in
            let content: ClipboardContent
            switch p.type {
            case "text":
                guard let str = p.text else { return nil }
                content = .text(str)
            case "image":
                let raw: Data? = {
                    if let rel = p.imageBlob, let d = self.readBlob(rel) { return d }
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
                guard let rel = p.imageBlob, let raw = self.readBlob(rel),
                      let typeMap = try? JSONDecoder().decode([String: Data].self, from: raw),
                      !typeMap.isEmpty else { return nil }
                seedPayload[p.id] = rel
                content = .blob(typeMap)
            case "group":
                guard let groupContent = self.decodeContent(p) else { return nil }
                content = groupContent
            default:
                return nil
            }
            var item = ClipboardItem(content: content, id: p.id, timestamp: p.timestamp,
                                     urlTitle: p.urlTitle, sourceAppName: p.sourceAppName,
                                     userNote: p.userNote, ocrText: p.ocrText)
            item.isPinned = p.isPinned
            // Unfiled is the normal resting state — histories written before
            // Collections existed simply stay unfiled and show under All.
            item.collections = Set(p.collections ?? [])
            // Restore the edited-file marker so "Revert to Original" still works
            // after a relaunch.
            if let orig = p.originalFilePath { item.originalFileURL = URL(fileURLWithPath: orig) }
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
            if let rel = p.sidecarBlob, let raw = self.readBlob(rel),
               let sidecar = try? JSONDecoder().decode([String: Data].self, from: raw),
               !sidecar.isEmpty {
                item.sidecarTypes = sidecar
                seedSidecar[p.id] = rel
            }
            return item
        }
        return HistoryDecodedBatch(items: loaded, seedImage: seedImage, seedPayload: seedPayload,
                                   seedSidecar: seedSidecar, migratedInlineEmbedding: migratedInlineEmbedding)
    }

    private func mergeHistoryBlobCaches(_ batch: HistoryDecodedBatch) {
        saveQueue.async { [weak self] in
            guard let self else { return }
            self.imageBlobCache.merge(batch.seedImage)     { _, new in new }
            self.payloadBlobCache.merge(batch.seedPayload) { _, new in new }
            self.sidecarBlobCache.merge(batch.seedSidecar) { _, new in new }
            if batch.migratedInlineEmbedding { self.embeddingsDirty = true }
        }
    }

    private func performHistoryLoadOffMain() {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601

        // ---- INSTANT HEAD PAINT ----
        // Read the tiny head sidecar FIRST and paint it immediately. Decoding
        // ~45 items is near-instant regardless of total history size, so the
        // window shows real, fully-usable clips right away instead of a blank
        // placeholder — no waiting on the whole encrypted manifest (with every
        // inline RTF blob) to decode. Embeddings are skipped here; the full
        // load's priority publish below carries them, and supersedes this with
        // an identical id/order set (no flash) before any search can run.
        var shownHeadIDs = Set<UUID>()
        if let headPersisted = readManifest(at: historyHeadURL, dec: dec), !headPersisted.isEmpty {
            let headBatch = decodeHistoryBatch(headPersisted, loadedEmbeddings: [:])
            if !headBatch.items.isEmpty {
                mergeHistoryBlobCaches(headBatch)
                shownHeadIDs = Set(headBatch.items.map(\.id))
                let headItems = headBatch.items
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.hasLoadedHistoryOnce else { return }
                    let captures = self.items
                    if captures.isEmpty {
                        self.items = headItems
                    } else {
                        let capturedIDs = Set(captures.map(\.id))
                        self.items = captures + headItems.filter { !capturedIDs.contains($0.id) }
                    }
                    self.hasLoadedHistoryOnce = true
                }
            }
        }

        let primaryExisted = FileManager.default.fileExists(atPath: historyFileURL.path)

        var persisted = readManifest(at: historyFileURL, dec: dec)

        if persisted == nil, !primaryExisted,
           let legacy = try? Data(contentsOf: legacyPlaintextHistoryURL) {
            if let cipher = HistoryCrypto.encrypt(legacy) {
                try? cipher.write(to: historyFileURL, options: [.atomic, .completeFileProtection])
            }
            try? FileManager.default.removeItem(at: legacyPlaintextHistoryURL)
            do {
                persisted = try dec.decode([PersistedItem].self, from: legacy)
            } catch {
                NSLog("[Clipen] loadHistory: legacy plaintext migration decode failed — %@", error.localizedDescription)
            }
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

        // Auto-recover wrongly-quarantined history. A `history.clip.corrupt-*`
        // file is only quarantined on a decode failure — but that failure can
        // be transient or schema-related (an older manifest the decoder of the
        // day rejected), NOT actual corruption. If such a file decodes cleanly
        // against TODAY's schema and holds more than we currently have, it's
        // real data that was lost — merge it back automatically so the user
        // never has to restore anything by hand. Each corrupt file is tried at
        // most once ever (tracked in UserDefaults), so this is free on every
        // normal launch (no corrupt files ⇒ instant no-op).
        if let recovered = recoverFromQuarantineIfBetter(current: persisted ?? [], dec: dec) {
            persisted = recovered
        }

        guard let persisted else {
            DispatchQueue.main.async { [weak self] in
                self?.historyLoadedCleanly = !primaryExisted
                self?.hasLoadedHistoryOnce = true
                self?.isHistoryFullyLoaded = true
                // Even an empty ring should trigger embedding init lazily so
                // the first search after populating doesn't cold-start it.
                self?.recomputeEmbeddingsInBackground()
            }
            return
        }
        let cleanLoad = true
        if !persisted.isEmpty, let goodBytes = try? Data(contentsOf: historyFileURL) {
            try? goodBytes.write(to: historyBackupURL, options: [.atomic, .completeFileProtection])
        }
        let loadedEmbeddings = readEmbeddingsFile()

        // The priority batch is decoded and published first, then the rest
        // streams in as background chunks. The head paint above already
        // showed these same priority items (from the sidecar) — this publish
        // supersedes them with an identical id/order set that also carries
        // embeddings, so there's no visible change, just a silent upgrade.
        let unpinnedPersisted  = persisted.filter { !$0.isPinned }
        let priorityPersisted  = Self.historyPrioritySlice(persisted)
        let deferredPersisted  = Array(unpinnedPersisted.dropFirst(Self.historyPriorityUnpinnedCount))

        let firstBatch = decodeHistoryBatch(priorityPersisted, loadedEmbeddings: loadedEmbeddings)
        mergeHistoryBlobCaches(firstBatch)
        let publish = firstBatch.items.filter(\.isPinned) + firstBatch.items.filter { !$0.isPinned }
        let publishIDs = Set(publish.map(\.id))

        // Every @Published mutation MUST land back on main.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.historyLoadedCleanly = cleanLoad
            // Keep genuine live captures (copied during load — ids in neither
            // the head paint nor the manifest); drop the provisional head
            // items (superseded by `publish`, same ids + embeddings) and any
            // stale head item no longer present in the manifest.
            let liveCaptures = self.items.filter {
                !shownHeadIDs.contains($0.id) && !publishIDs.contains($0.id)
            }
            self.items = liveCaptures + publish
            self.purgeLegacyDefaultCollection()
            self.embeddedItemCount = self.items.reduce(0) { $1.embedding == nil ? $0 : $0 + 1 }
            self.hasLoadedHistoryOnce = true
            Self.markEmbeddingSchemaCurrent()
            if deferredPersisted.isEmpty {
                // Nothing deferred — this publish already IS the complete
                // history, so it's now safe for auto-save/eviction to run.
                self.isHistoryFullyLoaded = true
                // Now that items are populated, kick off the embedding backfill
                // — it also lazily wakes the Neural-Engine model, on background.
                self.recomputeEmbeddingsInBackground()
                self.prewarmAllItems()
            }
        }

        guard !deferredPersisted.isEmpty else { return }

        // Everything past the priority batch decodes in the background, in
        // chunks, appended to `items` as each chunk finishes — so a very
        // large history keeps arriving progressively instead of holding up
        // the embedding backfill (and the rest of startup) behind one giant
        // decode pass.
        let deferredChunkSize = 100
        var start = 0
        while start < deferredPersisted.count {
            let end = min(start + deferredChunkSize, deferredPersisted.count)
            let chunk = Array(deferredPersisted[start..<end])
            let batch = decodeHistoryBatch(chunk, loadedEmbeddings: loadedEmbeddings)
            mergeHistoryBlobCaches(batch)
            let isLastChunk = end >= deferredPersisted.count
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let existingIDs = Set(self.items.map(\.id))
                let newOnes = batch.items.filter { !existingIDs.contains($0.id) }
                self.items.append(contentsOf: newOnes)
                self.embeddedItemCount = self.items.reduce(0) { $1.embedding == nil ? $0 : $0 + 1 }
                if isLastChunk {
                    // Every deferred chunk has now landed — the full history
                    // is finally in `items`, so auto-save/eviction may run.
                    self.isHistoryFullyLoaded = true
                    self.recomputeEmbeddingsInBackground()
                    self.prewarmAllItems()
                }
            }
            start = end
        }
    }

    /// Undoes beta 1.0.252's pre-made "Personal" collection: drops it from the
    /// collection list and unstamps it from every clip, exactly once. Scoped to
    /// that one name so collections the user made themselves are untouched.
    private func purgeLegacyDefaultCollection() {
        let key = "clipen.purgedLegacyDefaultCollection"
        guard !UserDefaults.standard.bool(forKey: key) else { return }

        let legacy = Self.legacyDefaultCollectionName
        var changed = collections.contains(legacy)
        collections.removeAll { $0 == legacy }
        for i in items.indices where items[i].collections.contains(legacy) {
            items[i].collections.remove(legacy)
            changed = true
        }
        if activeCollection == legacy { activeCollection = nil }

        // Only mark the purge done once the unstamped items are actually on
        // disk — otherwise a quit before the next save would strand the flag
        // set and the stamps still persisted.
        guard changed else {
            UserDefaults.standard.set(true, forKey: key)
            return
        }
        DispatchQueue.main.async { [weak self] in
            self?.saveHistory()
            UserDefaults.standard.set(true, forKey: key)
        }
    }

    // v3: embeddings now come from ClipenEmbedder (Neural-Engine contextual
    // model when available) — different dimensionality than the old sentence
    // embedding, so bump the version to discard stale vectors and re-index.
    private static let embeddingSchemaVersion = 3
    private static let embeddingSchemaKey = "clipen.embeddingSchemaVersion"

    static var persistedEmbeddingSchemaIsCurrent: Bool {
        UserDefaults.standard.integer(forKey: embeddingSchemaKey) >= embeddingSchemaVersion
    }

    static func markEmbeddingSchemaCurrent() {
        UserDefaults.standard.set(embeddingSchemaVersion, forKey: embeddingSchemaKey)
    }

}
