import Foundation
import AppKit
import CryptoKit

private enum HistoryCrypto {
    static let keychainKey = "historyEncryptionKey"

    /// The key used to live in the login keychain — which made macOS pop the
    /// "Clipen wants to use your confidential information… enter password"
    /// dialog whenever the reading binary's code signature didn't match the
    /// one that created the item (debug vs release builds, re-signs). A
    /// clipboard manager should never ask for the system password, so the key
    /// now lives in a 0600-permission file next to the (still AES-GCM
    /// encrypted) history it protects — readable only by this macOS user
    /// account, the same protection every other app's private files get.
    ///
    /// The old keychain entry is deleted WITHOUT ever being read — reading it
    /// is exactly what triggers the password prompt, so even a one-time
    /// migration read is skipped. Trade-off: any history encrypted under the
    /// old keychain key becomes unreadable and the ring starts empty once —
    /// deliberate, since zero prompts (not even once) was the ask.
    static var keyFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Clipen/history.key")
    }

    /// Resolved once per process (static let = thread-safe lazy) — the old
    /// implementation did a keychain roundtrip on EVERY encrypt/decrypt call,
    /// i.e. once per blob at launch.
    static let cachedKey: SymmetricKey = {
        if let data = try? Data(contentsOf: keyFileURL), data.count == 32 {
            return SymmetricKey(data: data)
        }
        // Never read the old keychain value — SecItemDelete alone doesn't
        // require unlocking the item, so this never prompts.
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
    // MARK: - User notes

    /// Attach or update a free-form user note on an item.
    /// Passing an empty string clears the note (stores nil).
    /// Triggers the normal debounced save via the $items publisher.
    func updateUserNote(id: UUID, note: String) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].userNote = note.isEmpty ? nil : note
        // Notes feed the semantic embedding now (richEmbeddingText), so an
        // edited note means a stale vector — wipe it and let the background
        // recompute rebuild it, same as when OCR text arrives late. Cheap:
        // note commits are already debounced upstream, so this isn't
        // re-embedding per keystroke.
        items[idx].embedding = nil
        lastSearchQuery = nil // same stale-cache reasoning as replaceItemContent
        recomputeEmbeddingsInBackground()
    }

    /// Overwrite a text item's content with user-edited text (Save in the
    /// reference panel). `content` and everything derived from it (detected
    /// type, tags, search haystacks) are immutable by design, so this builds
    /// a REPLACEMENT item with the same identity + history metadata and swaps
    /// it into the ring — the popup, main window, and search all pick the new
    /// text up through the normal items-changed path, and the debounced
    /// persistence pass saves it to disk.
    /// Plain text extracted from whichever content type the item actually
    /// holds — text, richText, html, or rtfd. Shared by the reference
    /// panel's editable views (plain-text box AND table-cell grid) so they
    /// don't each re-derive it.
    static func editablePlainText(for item: ClipboardItem) -> String? {
        item.content.plainText
    }

    /// Overwrite an item's content with edited plain text (Save in the
    /// reference panel's plain-text editor). Accepts any content type with
    /// a plain-text representation — richText/HTML/RTFD included — but
    /// always writes back as plain `.text`: reconstructing rich formatting
    /// from a hand-edited string isn't attempted, so an edit deliberately
    /// downgrades to plain text rather than silently keeping stale
    /// formatting bytes that no longer match the edited words.
    func updateItemText(id: UUID, newText: String) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        let old = items[idx]
        guard Self.editablePlainText(for: old) != nil,
              Self.editablePlainText(for: old) != newText else { return }
        replaceItemContent(id: id, newContent: .text(newText))
    }

    /// Overwrite an item's content with an edited table grid (Save in the
    /// reference panel's table-cell editor). Rebuilds as HTML `<table>`
    /// markup (not plain `.text`) so the "this is a table" structure survives
    /// the edit — pasting into any HTML-aware destination still gets real
    /// table cells, not a flattened blob of tab-separated text.
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

    /// Shared plumbing for the two content-replacing edits above: build a
    /// fresh ClipboardItem with the same identity + history metadata as
    /// `old` (content and everything derived from it — detected type, tags,
    /// search haystacks — are immutable by design, so an edit is always a
    /// full replacement, never a mutation).
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
        // embedding + ocrText deliberately NOT carried over — both describe
        // the OLD content. The background embedding pass re-fills the nil.
        items[idx] = updated
        // Cached blob paths describe the OLD payload — next save must rewrite.
        invalidateBlobCaches(for: id)
        // hybridSearch's result cache keys on (query, items.count,
        // embeddedItemCount) — a content edit changes NEITHER count (the
        // embed counter only bumps once the async re-embed lands), so
        // repeating the same query right after an edit returned results
        // ranked against the OLD text. Drop the cached query explicitly.
        lastSearchQuery = nil
        recomputeEmbeddingsInBackground()
    }

    // MARK: - File snapshot eviction

    /// Deletes the `Clipen/FileCopies/<UUID>/` directory for file items that
    /// were snapshotted by FileSnapshotStore. Called whenever an item leaves
    /// the ring so disk usage doesn't grow without bound.
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
        // Snapshot copies live in per-item UUID folders — remove the folder.
        let dirs = Set(urls
            .filter { $0.path.hasPrefix(snapshotBase) }
            .map    { $0.deletingLastPathComponent() })
        for dir in dirs {
            try? FileManager.default.removeItem(at: dir)
        }
        // Tool-generated outputs (Reduce PDF/Image, Convert, Pages-as-PNG)
        // land under Clipen/Optimized and Clipen/Converted as flat files —
        // they were never deleted when their ring item evicted, accumulating
        // forever. Remove the file itself (and, for the per-run
        // "PDF-Pages-<uuid>" subfolders under Optimized, the folder).
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
        items[idx].isPinned.toggle()
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

    /// Apply the ring-size cap. The user picks their preferred size (persisted
    /// in `preferredRingSize`) clamped to `cap`; first-time users default to 20.
    func applyPlanLimits(ringLimit cap: Int) {
        let preferred = UserDefaults.standard.object(forKey: "preferredRingSize") as? Int
        let target = max(1, preferred.map { min($0, cap) } ?? 20)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.maxItems != target else { return }
            self.maxItems = target
        }
    }

    // (No cloud sync in this build — it's a local-only clipboard manager.
    //  All "merge cloud items" helpers were removed during cleanup.)







    // MARK: - Persistence

    private struct PersistedItem: Codable {
        let id:        UUID
        let timestamp: Date
        let isPinned:  Bool
        let urlTitle:  String?
        let type:      String   // "text" | "image" | "richText" | "file"
        let text:      String?
        let imageData: Data?         // legacy inline path (kept for old files)
        let imageBlob: String?       // NEW: relative path under blobs/ when split out
        let imageType: String?
        let rtfData:   Data?
        let plainText: String?
        let filePath:  String?
        let filePaths: [String]?
        let html:      String?
        let sourceAppName: String?
        let sourceBundleID: String?
        // LEGACY READ-ONLY: embeddings used to ride inline here (~6 KB of
        // JSON floats per item — every debounced save re-encrypted all of
        // them). They now live in embeddings.clip as an id→vector
        // dictionary; this field is kept solely so old manifests still
        // decode, read once at load as the migration source, always written
        // as nil.
        let embedding: [Float]?
        /// Where the item was most recently pasted.  Optional — old manifests
        /// (pre-v1.0.47) won't have these fields and decode as nil.
        let pastedToAppName:  String?
        let pastedToBundleID: String?
        let lastPastedAt:     Date?
        /// Frequency signals for the predictor.  Optional for backward compat
        /// — manifests written before the predictor landed decode as nil → 0 / [:].
        let pasteCount:        Int?
        let pasteCountByApp:   [String: Int]?
        /// All destination app names ever recorded for this item.  Optional —
        /// old manifests decode as nil, synthesised from pastedToAppName below.
        let pastedToAppNames:  [String: String]?
        /// Optional for backward compat — manifests written before this field
        /// decode it as nil. Declared `var` with default so existing call sites
        /// that omit it still compile via the synthesised memberwise init.
        var userNote: String? = nil
        /// Vision OCR / PDFKit text extracted from image and PDF items.
        var ocrText: String? = nil
        /// Relative blobs/ path of the JSON-encoded side-car type map (the
        /// non-primary pasteboard flavors captured with the item). Optional —
        /// old manifests decode as nil; items without side-car write nil.
        var sidecarBlob: String? = nil

        /// Build a PersistedItem, copying all the shared per-item metadata
        /// (source app, embedding, paste stats, notes, OCR…) from `item` in
        /// one place. Callers pass only the fields that differ by content
        /// type. Replaces ~10 hand-copied constructor calls that each
        /// repeated the same trailing arguments verbatim.
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
                // Deliberately nil: embeddings moved to their own dictionary
                // file (embeddings.clip). The field stays in PersistedItem
                // so manifests written by older builds still decode — read
                // once at load as the migration fallback, never written.
                embedding: nil,
                pastedToAppName: item.pastedToAppName, pastedToBundleID: item.pastedToBundleID,
                lastPastedAt: item.lastPastedAt, pasteCount: item.pasteCount,
                pasteCountByApp: item.pasteCountByApp, pastedToAppNames: item.pastedToAppNames,
                userNote: item.userNote, ocrText: item.ocrText)
        }
    }

    /// Encrypted-at-rest history. `.clip` extension instead of `.json` so
    /// nobody mistakes the contents for a readable file.
    var historyFileURL: URL {
        historyDir.appendingPathComponent("history.clip")
    }

    /// Encrypted id→vector dictionary of every item's semantic embedding —
    /// split OUT of the manifest on purpose. Embeddings are ~6 KB of JSON
    /// floats per item (512 dims — the old "~2 KB" estimate was wrong), so
    /// carrying them inline meant every debounced save re-encoded and
    /// re-encrypted a megabyte-class manifest even when only a paste counter
    /// changed. Now the manifest stays small and this file is rewritten only
    /// when an embedding actually changed (see embeddingsDirty).
    var embeddingsFileURL: URL {
        historyDir.appendingPathComponent("embeddings.clip")
    }

    /// The id→vector dictionary from disk, or [:] on first launch / missing
    /// file (old installs migrate from the manifest's inline embeddings —
    /// see loadHistory).
    func readEmbeddingsFile() -> [String: [Float]] {
        guard let cipher = try? Data(contentsOf: embeddingsFileURL),
              let plain  = HistoryCrypto.decrypt(cipher),
              let dict   = try? JSONDecoder().decode([String: [Float]].self, from: plain)
        else { return [:] }
        return dict
    }

    /// Rewrites the embeddings dictionary from `snapshot` iff something
    /// changed since the last write. Runs on saveQueue (called from
    /// saveHistory). Writing the full dictionary (not a delta) keeps it
    /// self-healing: evicted items simply stop appearing, so the file can
    /// never accumulate orphaned vectors.
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
            // Leave the flag set — retried on the next save.
        }
    }

    /// Path to the v1 plaintext history file. Read once on first launch
    /// after upgrade, re-encrypt, and delete.
    var legacyPlaintextHistoryURL: URL {
        historyDir.appendingPathComponent("history.json")
    }

    /// Root directory for per-item binary blobs (image data, large rtf etc.),
    /// sharded by primary tag so the directory tree doubles as a sanity
    /// check when inspecting Application Support.  Each blob is its OWN
    /// AES-GCM encrypted file — the manifest only stores a relative path,
    /// not the bytes.  Goal: history.clip stays small (manifest only) so
    /// the 1-second debounced rewrite is cheap regardless of ring size or
    /// image dimensions.  No 8 MB image cap needed when bytes don't live
    /// in the manifest.
    var blobsDir: URL {
        historyDir.appendingPathComponent("blobs", isDirectory: true)
    }

    /// Reuse a cached blob path if its file still exists and the byte count
    /// matches; otherwise write a fresh blob and cache it.
    func reuseOrWriteBlob(cached: (path: String, bytes: Int)?,
                                  data: Data,
                                  primaryTag: ClipboardTag) -> String? {
        if let cached, cached.bytes == data.count,
           FileManager.default.fileExists(atPath: blobsDir.appendingPathComponent(cached.path).path) {
            return cached.path
        }
        return writeBlob(data, primaryTag: primaryTag)
    }

    /// Drop any cached blob paths for an item whose content is being replaced
    /// (transforms, edits) so the next save writes fresh payloads. The old
    /// payload's blob is now orphaned → flag the purge too.
    func invalidateBlobCaches(for id: UUID) {
        saveQueue.async { [weak self] in
            self?.imageBlobCache[id] = nil
            self?.payloadBlobCache[id] = nil
            self?.sidecarBlobCache[id] = nil
            self?.blobPurgeNeeded = true
        }
    }

    /// Call from any path that removes an item from the ring (delete,
    /// eviction, clear, ring-size trim) — its blob files are now
    /// unreferenced, so the next save must run the orphan sweep. One shared
    /// helper so no removal site hand-rolls the saveQueue hop.
    func markBlobPurgeNeeded() {
        saveQueue.async { [weak self] in self?.blobPurgeNeeded = true }
    }

    /// Write encrypted `data` to a new blob under `blobs/<tagDir>/<uuid>.bin`
    /// and return the relative path ("image/abcd-1234.bin") for storage in
    /// the manifest.  Returns nil on failure — caller falls back to inline.
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

    /// Inverse of `writeBlob`.  Loads `blobs/<relative>`, AES-decrypts, returns
    /// plaintext bytes or nil if the file is missing / corrupt / re-keyed.
    func readBlob(_ relativePath: String) -> Data? {
        let fileURL = blobsDir.appendingPathComponent(relativePath)
        guard let cipher = try? Data(contentsOf: fileURL),
              let plain  = HistoryCrypto.decrypt(cipher) else { return nil }
        return plain
    }

    /// Delete any blob files in `blobsDir` that are no longer referenced by
    /// the current `items` ring.  Called after every save so the directory
    /// can't accumulate orphans as the ring evicts old captures.
    func purgeOrphanBlobs(referenced: Set<String>) {
        guard let enumerator = FileManager.default.enumerator(
            at: blobsDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]) else { return }
        for case let url as URL in enumerator {
            guard let isFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile,
                  isFile else { continue }
            // Build the same "<tagDir>/<file>.bin" relative path that
            // writeBlob returns so the comparison key is consistent.
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
        // Track which blob paths the new manifest references; everything
        // ELSE in blobsDir gets purged at the end of this call so evicted
        // items can't leak bytes on disk forever.
        var referencedBlobs: Set<String> = []

        let itemsToSave = snapshot ?? items
        let persisted: [PersistedItem] = itemsToSave.compactMap { item in
            var p = persistedBase(for: item, referencedBlobs: &referencedBlobs)
            // Side-car flavors ride in their own encrypted blob file (same
            // infrastructure as image bytes / blob items) so the manifest
            // stays a small, cheap-to-rewrite index. Side-cars are immutable
            // after capture, so an already-written blob is reused as-is.
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
        // Keep the rolling backup current — but only from sessions that
        // loaded the previous manifest successfully AND have something to
        // save. A session recovering from a corrupt manifest must never
        // overwrite the backup that may be the only surviving good copy.
        if historyLoadedCleanly, !itemsToSave.isEmpty {
            try? cipher.write(to: historyBackupURL, options: [.atomic, .completeFileProtection])
        }
        // Embeddings live in their own dictionary file, rewritten only when
        // one actually changed — not on every manifest save.
        saveEmbeddingsIfDirty(snapshot: itemsToSave)
        // Drop blob files no longer referenced by the manifest — but only
        // when something could actually have been orphaned (removal,
        // eviction, content replacement). Runs after the manifest is on disk
        // so a crash in the middle can never leave the manifest pointing at
        // a deleted blob. NEVER runs in a session whose load didn't verify
        // cleanly: with an empty/partial ring loaded, every blob of the real
        // history would look "orphaned" and get destroyed.
        if blobPurgeNeeded && historyLoadedCleanly {
            purgeOrphanBlobs(referenced: referencedBlobs)
            blobPurgeNeeded = false
        }
    }

    /// The per-content-type PersistedItem construction saveHistory uses —
    /// split out so saveHistory can uniformly attach the side-car blob after.
    private func persistedBase(for item: ClipboardItem,
                               referencedBlobs: inout Set<String>) -> PersistedItem? {
            switch item.content {
            case .text(let str):
                return .make(from: item, type: "text", text: str, urlTitle: item.urlTitle)

            case .image(_, let rawData, let dataType):
                // Image bytes never go in the manifest — written to an encrypted
                // blob under blobs/image/<uuid>.bin, manifest carries only the
                // relative path. The blob is written ONCE per item and reused
                // on subsequent saves (image bytes are immutable after capture).
                // Falls back to inline (size-capped) if the blob write fails so
                // a disk hiccup never silently drops the capture.
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
                // Encode the full type→data map as JSON into a blob file using
                // the same encrypted blob infrastructure as images. Immutable
                // after capture → written once, reused on every later save.
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

    /// Rolling backup of the last known-good manifest. Written after every
    /// successful load and every successful non-empty save, and used as the
    /// fallback when the primary manifest turns out to be unreadable.
    var historyBackupURL: URL {
        historyDir.appendingPathComponent("history.clip.bak")
    }

    /// Read + decrypt + decode a manifest file, or nil if ANY step fails.
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

        // Prefer the encrypted primary manifest.
        var persisted = readManifest(at: historyFileURL, dec: dec)

        // If the primary is missing but a legacy plaintext history exists,
        // migrate it once: re-encrypt under the user's key, then delete the
        // plaintext copy so the secrets-on-disk window closes on the first
        // launch after upgrade.
        if persisted == nil, !primaryExisted,
           let legacy = try? Data(contentsOf: legacyPlaintextHistoryURL) {
            if let cipher = HistoryCrypto.encrypt(legacy) {
                try? cipher.write(to: historyFileURL, options: [.atomic, .completeFileProtection])
            }
            try? FileManager.default.removeItem(at: legacyPlaintextHistoryURL)
            persisted = try? dec.decode([PersistedItem].self, from: legacy)
        }

        // The primary EXISTS but can't be read (truncated write, decrypt or
        // decode failure). This must NEVER silently become "fresh install":
        // that exact path once let a fresh session overwrite the manifest
        // and purge every blob it didn't know about, destroying the user's
        // entire history. Quarantine the unreadable file for post-mortem,
        // then fall back to the rolling backup.
        if persisted == nil, primaryExisted {
            let stamp = Int(Date().timeIntervalSince1970)
            let quarantine = historyDir.appendingPathComponent("history.clip.corrupt-\(stamp)")
            try? FileManager.default.moveItem(at: historyFileURL, to: quarantine)
            NSLog("[Clipen] loadHistory: primary manifest unreadable — quarantined to \(quarantine.lastPathComponent), trying backup")
            if let fromBackup = readManifest(at: historyBackupURL, dec: dec) {
                persisted = fromBackup
                // Reinstate the primary from the backup bytes so the next
                // launch is back on the normal path.
                if let bakBytes = try? Data(contentsOf: historyBackupURL) {
                    try? bakBytes.write(to: historyFileURL, options: [.atomic, .completeFileProtection])
                }
                NSLog("[Clipen] loadHistory: restored \(fromBackup.count) items from history.clip.bak")
            }
        }

        guard let persisted else {
            // Nothing readable anywhere. Only treat this as a CLEAN state on
            // a true fresh install (no manifest ever existed) — if one
            // existed and we couldn't read or recover it, stay in the
            // suspect state: saves still persist new captures, but the
            // orphan-blob purge stays disabled all session so surviving
            // payloads of the lost history can't be swept away.
            historyLoadedCleanly = !primaryExisted
            return
        }
        historyLoadedCleanly = true
        // Refresh the rolling backup from the now-verified primary.
        if !persisted.isEmpty, let goodBytes = try? Data(contentsOf: historyFileURL) {
            try? goodBytes.write(to: historyBackupURL, options: [.atomic, .completeFileProtection])
        }
        // Blob paths seen while decoding — seeded into the save-side caches so
        // the FIRST debounced save after launch reuses these files instead of
        // re-encrypting every payload to fresh UUIDs.
        var seedImage:   [UUID: (path: String, bytes: Int)] = [:]
        var seedPayload: [UUID: String] = [:]
        var seedSidecar: [UUID: String] = [:]
        // Embeddings live in their own dictionary file (id → vector), NOT in
        // the manifest — see saveEmbeddingsIfDirty for why. Loaded once here;
        // `migratedInlineEmbedding` flips when any embedding is still found
        // inline in an old manifest, so the first save writes the dictionary
        // file and the rewritten manifest drops the inline copies for good.
        let loadedEmbeddings = readEmbeddingsFile()
        var migratedInlineEmbedding = false
        let allLoaded = persisted.compactMap { p -> ClipboardItem? in
            let content: ClipboardContent
            switch p.type {
            case "text":
                guard let str = p.text else { return nil }
                content = .text(str)
            case "image":
                // New format: imageBlob → read from blobs/<tag>/<uuid>.bin.
                // Legacy format: imageData inline in the manifest.  Drop the
                // item silently if neither resolves (file deleted, corrupt).
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
            // userNote/ocrText ride the initializer so their didSet haystack
            // rebuilds don't fire — one haystack build per item at load, not
            // three (see the init's doc comment).
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
            // Restore the full set of destination-app names.  For items
            // written by earlier builds (pre-1.0.49) we synthesise a single
            // entry from pastedToAppName + pastedToBundleID so the badges
            // are still populated on first launch after upgrade.
            if let names = p.pastedToAppNames, !names.isEmpty {
                item.pastedToAppNames = names
            } else if let bid = p.pastedToBundleID, let name = p.pastedToAppName {
                item.pastedToAppNames = [bid: name]
            }
            // Restore the persisted embedding so semantic search is HOT from
            // launch. Primary source: the embeddings dictionary file (keyed
            // by item id — see saveEmbeddingsIfDirty). Fallback for history
            // written by older builds: the inline `embedding` field the
            // manifest used to carry — read once here, and the next save
            // migrates it out (manifest rewrites drop the inline copy; the
            // dictionary file becomes the single home). Skipped entirely
            // after an embedding schema bump (see embeddingSchemaVersion):
            // vectors computed under an older scheme would otherwise persist
            // forever, since the recompute pass only fills nil embeddings.
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
            // Old-format manifest carried embeddings inline — force one
            // embeddings-file write so the migration completes on the very
            // first save (which also rewrites the manifest without them).
            if needsEmbeddingMigration { self.embeddingsDirty = true }
        }
        // Load everything that was persisted — do NOT truncate to maxItems
        // here. maxItems starts at a hardcoded placeholder (10) and only
        // gets its real value (the user's actual configured ring size, up
        // to 200) moments later via AuthManager.applyPlanLimits, which
        // defers its assignment a full runloop tick. loadHistory runs
        // synchronously before that lands, so truncating HERE used to trim
        // to 10 on every single launch — and since the debounced autosave
        // then wrote that truncated array back to disk ~1s later, everything
        // past the first 10 unpinned items was silently deleted for good.
        // maxItems's own didSet already re-trims once the real size is set
        // (moments after this runs), which is the correct place for it.
        let pinned   = allLoaded.filter { $0.isPinned }
        let unpinned = allLoaded.filter { !$0.isPinned }
        items = pinned + unpinned
        // Loaded items have no embeddings yet (recomputeEmbeddingsInBackground
        // re-fills them); reset the counter so the search cache invalidates
        // correctly as those fills land.
        embeddedItemCount = items.reduce(0) { $1.embedding == nil ? $0 : $0 + 1 }
        Self.markEmbeddingSchemaCurrent()
    }

    /// Bump this whenever WHAT gets embedded changes (not just cosmetics):
    /// v2 = richEmbeddingText (content + OCR + notes + titles + paste-app
    /// context) replacing bare textForEmbedding. On the first launch after
    /// a bump, persisted vectors are discarded once (see loadHistory) and
    /// recomputeEmbeddingsInBackground rebuilds every item under the new
    /// scheme; subsequent launches restore from disk as usual.
    private static let embeddingSchemaVersion = 2
    private static let embeddingSchemaKey = "clipen.embeddingSchemaVersion"

    static var persistedEmbeddingSchemaIsCurrent: Bool {
        UserDefaults.standard.integer(forKey: embeddingSchemaKey) >= embeddingSchemaVersion
    }

    static func markEmbeddingSchemaCurrent() {
        UserDefaults.standard.set(embeddingSchemaVersion, forKey: embeddingSchemaKey)
    }

}
