import AppKit
import SwiftUI
import Vision
import NaturalLanguage
@preconcurrency import PDFKit

extension ClipboardManager {
    // MARK: - Polling

    func startPolling() {
        lastChangeCount = NSPasteboard.general.changeCount
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            self?.pollClipboard()
        }
        RunLoop.main.add(pollTimer!, forMode: .common)
    }

    func pollClipboard() {
        // User-requested pause (e.g. before entering a password)
        guard !isCapturingPaused else { return }

        guard !isSimulatingPaste else { return }
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }

        // Honor the nspasteboard.org convention: password managers (1Password,
        // Bitwarden, …) tag sensitive copies with these sentinel types
        // specifically so clipboard managers skip them. Consume the changeCount
        // (so we don't re-evaluate this same generation next tick) but never
        // capture, index, or persist the content.
        if Self.pasteboardIsConcealed(pb) {
            lastChangeCount = pb.changeCount
            return
        }

        if !remoteClipboardDataReady(pb) {
            remoteClipboardRetryCount += 1
            if remoteClipboardRetryCount < Self.maxRemoteClipboardRetries {
                // Don't consume changeCount yet — the iPhone's image/file
                // bytes are still streaming in over Continuity; try again
                // on the next poll tick against this SAME pasteboard
                // generation (it will never bump changeCount again once
                // the real data lands).
                return
            }
            // Gave up waiting — consume changeCount so this doesn't retry
            // forever, and fall through to capture whatever's actually
            // there now (a clean "nothing useful" rather than a stuck loop).
            remoteClipboardLastFileSize.removeAll()
        }
        remoteClipboardRetryCount = 0
        lastChangeCount = pb.changeCount

        // Snapshot EVERY representation on this pasteboard change up front —
        // async capture branches below resolve after the pasteboard may have
        // changed again, so the full-fidelity side-car must be read now.
        // Pruned per item (types the primary content re-writes itself are
        // dropped) in addCaptured before being attached.
        let sidecarSnapshot = Self.allPasteboardTypes(from: pb)

        // 1. File URLs
        if captureFiles {
            let urls = fileURLs(from: pb)
            if !urls.isEmpty {
            // Copy files off the main thread — large files (video, archives) would
            // otherwise block the UI for the entire duration of the file copy.
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let snapshots = FileSnapshotStore.snapshot(urls)
                // Every file failed to copy (see FileSnapshotStore) — nothing
                // usable was actually captured, so don't add a hollow
                // .files([]) item to the ring.
                guard !snapshots.isEmpty else { return }
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.addCaptured(ClipboardItem(content: snapshots.count == 1
                        ? .file(snapshots[0]) : .files(snapshots)), sidecar: sidecarSnapshot)
                }
            }
            return
            }

            // 1b. Promised files — apps like Mail, Photos, Safari and many
            // editing tools don't put a real file on the pasteboard; they put a
            // *promise* that materializes the file only when the receiver asks.
            // Normal ⌘C→⌘V works because the destination app triggers that
            // callback; Clipen has to trigger it itself. Resolve into a temp dir
            // and add the item asynchronously when the file(s) land — never drop.
            if resolvePromisedFiles(from: pb) { return }
        }

        // 2. RTFD — BEFORE HTML on purpose: RTFD is the only flavor that
        // carries embedded image BYTES alongside text and tables. Mixed
        // copies from Notes/Pages/Word/TextEdit put both RTFD and an HTML
        // rendition on the pasteboard, and the HTML version usually
        // references its images by file path or drops them entirely — so
        // capturing HTML first stored the lossy rendition as the primary
        // and the only image-bearing flavor was demoted to the side-car.
        // Web copies are unaffected: browsers don't write RTFD, so they
        // fall through to the HTML branch exactly as before.
        if captureRichText, let rtfdData = pb.data(forType: .rtfd) {
            let fallback = basicItem(from: pb)
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { return }
                let attrStr = NSAttributedString(rtfd: rtfdData, documentAttributes: nil)
                DispatchQueue.main.async {
                    if let attrStr, !attrStr.string.isEmpty {
                        self.addCaptured(ClipboardItem(content: .rtfd(rtfdData, plain: attrStr.string)), sidecar: sidecarSnapshot)
                    } else if let fallback {
                        self.addCaptured(fallback, sidecar: sidecarSnapshot)
                    }
                }
            }
            return
        }

        // 3. HTML (before RTF/plain text so web formatting survives).
        // The raw HTML string and the extracted plain-text both use
        // multi-encoding fallbacks so WhatsApp / Notes / Slack content —
        // which is often UTF-16 or wrapped in malformed wrappers WebKit's
        // sync parser chokes on — still captures correctly.  Without these
        // fallbacks, long pastes from those apps would silently drop.
        let htmlTypes: [NSPasteboard.PasteboardType] = [
            .init("public.html"),
            .init("Apple HTML pasteboard type")
        ]
        for type in htmlTypes {
            guard let htmlData = pb.data(forType: type) else { continue }
            let html: String? = String(data: htmlData, encoding: .utf8)
                ?? String(data: htmlData, encoding: .utf16)
                ?? String(data: htmlData, encoding: .utf16BigEndian)
                ?? String(data: htmlData, encoding: .utf16LittleEndian)
                ?? String(data: htmlData, encoding: .isoLatin1)
                ?? String(data: htmlData, encoding: .ascii)
            guard let html, !html.isEmpty else { continue }
            // Snapshot a synchronous fallback (plain text / image / blob) NOW, on
            // the current pasteboard, so that if the async WebKit parse fails or
            // yields no text (malformed markup, image-only fragments) we degrade
            // to a usable item instead of silently dropping the copy.
            let fallback = basicItem(from: pb)
            // Image-only HTML fast path: copying an image in Safari/Chrome puts a
            // `public.html` fragment that is just an <img> tag ALONGSIDE the real
            // image data. The <img> has no text, so the HTML branch would store an
            // empty "HTML" item. If a real image is available, prefer it outright.
            if case .image = fallback?.content, Self.isImageOnlyHTML(html) {
                if let fallback { addCaptured(fallback, sidecar: sidecarSnapshot) }
                return
            }
            // The plain-text version already on the pasteboard, if any. Used to
            // decide whether the HTML actually adds formatting worth keeping.
            let pasteboardPlain = pb.string(forType: .string)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // Detect structure that MUST survive: a <table>, or any <img>.
            // Either one means the HTML carries content the plain text
            // can't — never downgrade those. The <img> check matters for
            // mixed web selections (text + pictures, no table): images
            // contribute zero extracted text, so the "extracts to the same
            // text" test below matched and silently downgraded the copy to
            // plain text, throwing the pictures away.
            let htmlMustSurvive = Self.htmlContainsTable(html) || Self.htmlContainsImage(html)
            // Parse HTML off the main thread so large fragments never block
            // keyboard/paste responsiveness during capture.
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { return }
                // Treat whitespace-only extraction as empty so stray spaces from
                // tag-stripping don't masquerade as real text.
                let plain = Self.plainText(fromHTML: htmlData)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                DispatchQueue.main.async {
                    if let plain, !plain.isEmpty {
                        // Many apps attach a `public.html` wrapper even for ordinary
                        // text. If the HTML extracts to the SAME text already on the
                        // pasteboard AND there's no table structure, it carries no
                        // extra formatting — store as plain text so it isn't mislabeled.
                        // Tables are ALWAYS stored as HTML so their structure is preserved.
                        if !htmlMustSurvive,
                           let pasteboardPlain, !pasteboardPlain.isEmpty,
                           pasteboardPlain == plain {
                            self.addCaptured(ClipboardItem(content: .text(pasteboardPlain)), sidecar: sidecarSnapshot)
                        } else {
                            self.addCaptured(ClipboardItem(content: .html(html, plain: plain)), sidecar: sidecarSnapshot)
                        }
                    } else if let fallback {
                        self.addCaptured(fallback, sidecar: sidecarSnapshot)
                    }
                }
            }
            return
        }

        // 4. RTF (before plain text — RTF also exposes .string)
        if captureRichText, let rtfData = pb.data(forType: .rtf) {
            let fallback = basicItem(from: pb)
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { return }
                let attrStr = NSAttributedString(rtf: rtfData, documentAttributes: nil)
                // RTF that parsed with image attachments must NOT live as
                // .richText: both the persistence path and the paste path
                // re-encode .richText to bare RTF, and bare RTF cannot carry
                // attachments — the images silently vanished on the first
                // save AND on every paste. RTFD is the attachment-capable
                // container, so convert once here and store .rtfd, which
                // persists and pastes its bytes verbatim.
                let rtfdUpgrade: Data? = {
                    guard let attrStr, attrStr.containsAttachments else { return nil }
                    let range = NSRange(location: 0, length: attrStr.length)
                    return try? attrStr.data(from: range,
                                             documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
                }()
                DispatchQueue.main.async {
                    if let attrStr, !attrStr.string.isEmpty {
                        if let rtfdUpgrade {
                            self.addCaptured(ClipboardItem(content: .rtfd(rtfdUpgrade, plain: attrStr.string)), sidecar: sidecarSnapshot)
                        } else {
                            self.addCaptured(ClipboardItem(content: .richText(attrStr, plain: attrStr.string)), sidecar: sidecarSnapshot)
                        }
                    } else if let fallback {
                        self.addCaptured(fallback, sidecar: sidecarSnapshot)
                    }
                }
            }
            return
        }

        // 4. Everything else (plain text, SVG, image, opaque blob) — captured
        // synchronously and reliably via the shared `basicItem` builder.
        if let item = basicItem(from: pb) {
            addCaptured(item, sidecar: sidecarSnapshot)
            if fetchURLTitles, case .text(let str) = item.content {
                let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
                if let url = URL(string: trimmed),
                   url.scheme == "http" || url.scheme == "https" {
                    fetchURLTitle(for: item.id, url: url)
                }
            }
        } else {
            // Analytics: a pasteboard change we couldn't turn into ANY item
            // — the capture was effectively dropped.
            AuthManager.shared.registerActionUsage(actionID: "fail.capture")
        }
    }

    /// macOS tags Universal Clipboard (Handoff from iPhone/iPad) content with
    /// this marker type the instant it announces itself — before the actual
    /// bytes have necessarily finished streaming in over Continuity.
    static let remoteClipboardMarker = NSPasteboard.PasteboardType("com.apple.is-remote-clipboard")

    /// True unless this is Universal Clipboard content that's announced
    /// itself but isn't FULLY, STABLY readable yet — i.e. still mid-transfer
    /// from the source device. Non-remote content (the overwhelming common
    /// case) always returns true here immediately without touching the
    /// pasteboard beyond `.types`. Instance method (not static) because
    /// file-url stability tracking needs to remember sizes across polls.
    func remoteClipboardDataReady(_ pb: NSPasteboard) -> Bool {
        guard let types = pb.types, types.contains(Self.remoteClipboardMarker) else { return true }
        // A file-url type's "data" is just the URL STRING (the path text) —
        // that's available immediately, well before Continuity actually
        // finishes writing the real file to that path. Checking pb.data(for:)
        // alone (below) said "ready" the instant the path existed, even
        // though the file behind it was still empty/nonexistent — captured
        // that way, it copies zero (or partial) bytes, silently falls back
        // to the original transient path (see FileSnapshotStore), and breaks
        // for good once Apple cleans that temp path up.
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            var allStable = true
            for url in urls {
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                let key = url.path
                let previous = remoteClipboardLastFileSize[key]
                remoteClipboardLastFileSize[key] = size
                // Non-zero alone isn't enough — a file mid-write has real
                // bytes too, just not all of them. Require the SAME non-zero
                // size on two consecutive polls (0.3s apart) before trusting
                // the transfer is actually finished, not just in progress.
                if size == 0 || previous != size {
                    allStable = false
                }
            }
            if allStable {
                for url in urls { remoteClipboardLastFileSize.removeValue(forKey: url.path) }
            }
            return allStable
        }
        if let s = pb.string(forType: .string), !s.isEmpty { return true }
        for t in types where t != Self.remoteClipboardMarker {
            if let data = pb.data(forType: t), !data.isEmpty { return true }
        }
        return false
    }

    /// Sentinel pasteboard types (nspasteboard.org convention) that password
    /// managers and other privacy-conscious apps set to ask clipboard managers
    /// NOT to record a copy. Presence of any one means: skip capture entirely.
    static let concealedPasteboardTypes: Set<String> = [
        "org.nspasteboard.ConcealedType",
        "org.nspasteboard.TransientType",
        "org.nspasteboard.AutoGeneratedType",
    ]

    /// True when the pasteboard carries any "do not capture" sentinel type.
    static func pasteboardIsConcealed(_ pb: NSPasteboard) -> Bool {
        guard let types = pb.types else { return false }
        for t in types where concealedPasteboardTypes.contains(t.rawValue) { return true }
        return false
    }

    /// Every readable representation currently on the pasteboard, keyed by raw
    /// type identifier. Size-capped per type. This is the full-fidelity
    /// snapshot the side-car system starts from.
    static func allPasteboardTypes(from pb: NSPasteboard) -> [String: Data] {
        var map: [String: Data] = [:]
        for t in pb.types ?? [] {
            if let data = pb.data(forType: t), !data.isEmpty, data.count < Self.maxDataBytes {
                map[t.rawValue] = data
            }
        }
        return map
    }

    /// Add a freshly-captured item with its pasteboard side-car attached.
    /// All capture-path addItem calls funnel through here so every capture —
    /// text, image, rich text, files — keeps the OTHER flavors that were on
    /// the pasteboard with it, matching what a raw macOS copy preserves.
    func addCaptured(_ item: ClipboardItem, sidecar: [String: Data]) {
        var enriched = item
        enriched.sidecarTypes = Self.prunedSidecar(sidecar, for: item.content)
        // Analytics: captures per content type (image/text/url/pdf/…),
        // using the same tag names the blobs directory uses.
        AuthManager.shared.registerActionUsage(actionID: "capture.\(item.primaryTag.folderName)")
        addItem(enriched)
    }

    /// Drop side-car entries the primary content's write path already
    /// re-creates itself (so paste doesn't write the same flavor twice), and
    /// collapse to nil when nothing extra remains — the common case for
    /// ordinary text copies, which then cost zero extra storage.
    static func prunedSidecar(_ all: [String: Data],
                                      for content: ClipboardContent) -> [String: Data]? {
        if case .blob = content { return nil }  // blob IS the full set already
        var excluded: Set<String> = [
            "public.utf8-plain-text", "public.plain-text",
            "public.utf16-external-plain-text", "NSStringPboardType",
        ]
        switch content {
        case .richText:
            // public.rtf deliberately NOT excluded: the paste path prefers
            // the ORIGINAL rtf bytes from the side-car over its own
            // re-encode (see write's .richText case) — re-encoding through
            // NSAttributedString normalizes/drops things the source app's
            // rtf carried. Only the legacy alias is dropped.
            excluded.formUnion(["NSRTFPboardType"])
        case .rtfd:
            excluded.formUnion(["com.apple.flat-rtfd", "NSRTFDPboardType",
                                "public.rtf", "NSRTFPboardType"])
        case .html:
            excluded.formUnion(["public.html", "Apple HTML pasteboard type"])
        case .image(_, _, let dataType):
            excluded.formUnion([dataType.rawValue, "public.tiff", "NSTIFFPboardType"])
        case .svg:
            excluded.formUnion(["public.svg-image", "com.adobe.illustrator.svg", "org.w3.svg"])
        case .file, .files:
            excluded.formUnion(["public.file-url", "NSFilenamesPboardType"])
        case .text, .blob:
            break
        }
        let pruned = all.filter { !excluded.contains($0.key) }
        return pruned.isEmpty ? nil : pruned
    }

    /// Build the best non-HTML/RTF item from a pasteboard, in priority order:
    /// plain text → SVG → typed image → generic image → opaque blob passthrough.
    /// Returns nil only when nothing usable is present.  Pure: it does not add
    /// to history or trigger side effects, so it can serve both as the primary
    /// capture path AND as the synchronous fallback for a failed rich-text parse.
    func basicItem(from pb: NSPasteboard) -> ClipboardItem? {
        // Plain text
        if let str = pb.string(forType: .string), !str.isEmpty {
            return ClipboardItem(content: .text(str))
        }

        // SVG — before images so design-tool copies land here first.
        let svgTypes: [NSPasteboard.PasteboardType] = [
            .init("public.svg-image"),
            .init("com.adobe.illustrator.svg"),
            .init("org.w3.svg")
        ]
        for type in svgTypes {
            if let data = pb.data(forType: type),
               let str = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1),
               !str.isEmpty {
                return ClipboardItem(content: .svg(str))
            }
        }

        // Images — before blob so apps that add private metadata alongside
        // a public image (e.g. Photos, Preview, Affinity) are stored as images.
        let imageTypes: [NSPasteboard.PasteboardType] = [
            .init("public.png"), .tiff,
            .init("com.adobe.pdf"), .init("public.jpeg"), .init("public.heic"),
            .init("com.compuserve.gif"), .init("public.gif")
        ]
        for type in imageTypes {
            if let data = pb.data(forType: type), let img = NSImage(data: data) {
                // TIFF is uncompressed (~4 bytes/pixel) — a Retina screenshot
                // region runs 20-40 MB as TIFF vs 1-3 MB as PNG, and those
                // bytes live in RAM for the item's whole ring lifetime plus
                // get AES-encrypted to disk. Apps that only offer TIFF
                // (no public.png flavor) get transcoded once at capture.
                // The NSImage is rebuilt from the PNG so the original TIFF
                // buffer isn't retained by the image rep either.
                if type == .tiff, data.count > 1_000_000,
                   let png = img.pngData(), png.count < data.count,
                   let content = ClipboardContent.imageContent(rawData: png, dataType: .init("public.png"),
                                                               fallback: NSImage(data: png)) {
                    return ClipboardItem(content: content)
                }
                if let content = ClipboardContent.imageContent(rawData: data, dataType: type, fallback: img) {
                    return ClipboardItem(content: content)
                }
            }
        }
        if let img = NSImage(pasteboard: pb) {
            let data = img.pngData() ?? Data()
            if let content = ClipboardContent.imageContent(rawData: data, dataType: .init("public.png"), fallback: img) {
                return ClipboardItem(content: content)
            }
        }

        // Opaque passthrough — last resort when nothing above matched
        // (Photoshop layers without a public image, Sketch symbols, Procreate
        // clips, etc.). Re-writing all types on paste lets the source app
        // reconstruct its internal representation exactly.
        // NOTE: this priority ladder is mirrored by dist/capture_smoke_test.swift
        // (PasteboardClassifier). Keep the two in sync — the test guards it.
        // No trigger filter anymore: previously blob capture required at least
        // one NON-Apple/non-public private type, so a copy consisting solely
        // of exotic com.apple.* internal types (no public representation) was
        // dropped entirely. Raw macOS keeps those copies; now Clipen does too
        // — if ANY readable data is on the pasteboard, capture it verbatim.
        var blobMap: [String: Data] = [:]
        for t in pb.types ?? [] {
            if let data = pb.data(forType: t), !data.isEmpty, data.count < Self.maxDataBytes {
                blobMap[t.rawValue] = data
            }
        }
        if !blobMap.isEmpty {
            return ClipboardItem(content: .blob(blobMap))
        }

        return nil
    }

    func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        var urls: [URL] = []

        if let objects = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] {
            urls.append(contentsOf: objects)
        }

        let filenameType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
        if let paths = pasteboard.propertyList(forType: filenameType) as? [String] {
            urls.append(contentsOf: paths.map { URL(fileURLWithPath: $0) })
        }

        let fileURLTypes: [NSPasteboard.PasteboardType] = [
            .init("public.file-url"),
            .init("NSURLPboardType"),
            .init("Apple URL pasteboard type"),
            .init("com.apple.pasteboard.promised-file-url")
        ]

        for item in pasteboard.pasteboardItems ?? [] {
            for type in fileURLTypes {
                if let string = item.string(forType: type),
                   let url = parseFileURL(string) {
                    urls.append(url)
                } else if let data = item.data(forType: type),
                          let string = String(data: data, encoding: .utf8),
                          let url = parseFileURL(string) {
                    urls.append(url)
                }
            }

            if let paths = item.propertyList(forType: filenameType) as? [String] {
                urls.append(contentsOf: paths.map { URL(fileURLWithPath: $0) })
            }
        }

        if let string = pasteboard.string(forType: .string),
           let url = parseFileURL(string) {
            urls.append(url)
        }

        // Code editors (Cursor, VS Code) copy files from their explorer using a
        // private "code/file-list" type instead of the Finder-standard
        // public.file-url.  Without this, those copies fall through to the opaque
        // blob passthrough and get mislabeled "Private clipboard data" (and the
        // QuickLook preview spins/crashes).  Decode it into real file URLs so
        // they behave exactly like a Finder copy.
        let codeListTypes: [NSPasteboard.PasteboardType] = [
            .init("code/file-list"),
            .init("org.chromium.web-custom-data"),
            .init("vscode-editor-data")
        ]
        for type in codeListTypes {
            guard let data = pasteboard.data(forType: type),
                  let raw = String(data: data, encoding: .utf8)
                          ?? String(data: data, encoding: .utf16) else { continue }
            for line in raw.split(whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == "\u{0}" }) {
                if let url = parseFileURL(String(line)) { urls.append(url) }
            }
        }

        var seen = Set<String>()
        return urls.filter { url in
            guard url.isFileURL,
                  FileManager.default.fileExists(atPath: url.path),
                  !seen.contains(url.path) else { return false }
            seen.insert(url.path)
            return true
        }
    }

    /// Resolve drag/file promises (NSFilePromiseReceiver) into real files in a
    /// temp directory, then snapshot + capture them.  Returns true if a promise
    /// was found and resolution was kicked off (so the caller stops the ladder).
    ///
    /// Covers the case where an app (Mail, Photos, Safari, many editors) copies
    /// content as a promise rather than a concrete file — a normal paste makes
    /// the source app write the file on demand, and this does the same.
    func resolvePromisedFiles(from pb: NSPasteboard) -> Bool {
        guard let receivers = pb.readObjects(
            forClasses: [NSFilePromiseReceiver.self],
            options: nil
        ) as? [NSFilePromiseReceiver], !receivers.isEmpty else { return false }

        let destDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipenPromises/\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        // Serial queue so the completion handlers (which append to `resolved`)
        // never run concurrently — avoids a data race on the array.
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        var resolved: [URL] = []
        let group = DispatchGroup()

        for receiver in receivers {
            group.enter()
            receiver.receivePromisedFiles(atDestination: destDir,
                                          options: [:],
                                          operationQueue: queue) { url, error in
                if error == nil { resolved.append(url) }
                group.leave()
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            let existing = resolved.filter { FileManager.default.fileExists(atPath: $0.path) }
            guard !existing.isEmpty else { return }
            let snapshots = FileSnapshotStore.snapshot(existing)
            guard !snapshots.isEmpty else { return }
            self.addItem(ClipboardItem(
                content: snapshots.count == 1 ? .file(snapshots[0]) : .files(snapshots)))
        }
        return true
    }

    func parseFileURL(_ raw: String) -> URL? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains("\n") else { return nil }

        if text.hasPrefix("file://"),
           let url = URL(string: text.removingPercentEncoding ?? text),
           url.isFileURL {
            return url
        }

        if text.hasPrefix("/") || text.hasPrefix("~") {
            return URL(fileURLWithPath: (text as NSString).expandingTildeInPath)
        }

        return nil
    }

    /// True when an HTML fragment carries an <img> but no meaningful text —
    /// e.g. the `<meta><img src="…">` wrapper Safari/Chrome attach when you copy
    /// an image. Such fragments should yield the image, never an empty HTML item.
    static func isImageOnlyHTML(_ html: String) -> Bool {
        guard html.range(of: "<img", options: .caseInsensitive) != nil else { return false }
        let text = stripHTMLTags(html)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty
    }

    /// Returns true when the HTML fragment contains table markup (<table>, <tr>, <td>).
    /// Used to prevent downgrading structured table content to plain text.
    static func htmlContainsTable(_ html: String) -> Bool {
        html.range(of: "<table", options: .caseInsensitive) != nil
    }

    /// True when the HTML embeds/references any image — content the plain
    /// text extraction can't represent, so the HTML flavor must be kept.
    static func htmlContainsImage(_ html: String) -> Bool {
        html.range(of: "<img", options: .caseInsensitive) != nil
    }

    static func plainText(fromHTML data: Data) -> String? {
        // Stay on the lightweight path here: HTML capture only needs the plain
        // text for labeling / fallback decisions. Running NSAttributedString's
        // HTML importer spins up the attributed-string agent (and, on large
        // fragments, WebKit plumbing) on every copy, which is exactly the hot
        // path that makes big clipboard captures feel slow.
        let raw: String? = String(data: data, encoding: .utf8)
                       ?? String(data: data, encoding: .utf16)
                       ?? String(data: data, encoding: .utf16BigEndian)
                       ?? String(data: data, encoding: .utf16LittleEndian)
                       ?? String(data: data, encoding: .isoLatin1)
                       ?? String(data: data, encoding: .ascii)
        guard let html = raw, !html.isEmpty else { return nil }
        return stripHTMLTags(html)
    }

    /// Last-resort HTML→text: removes scripts/styles, strips tags, decodes
    /// the handful of named entities WhatsApp/Notes actually use, collapses
    /// whitespace.  Not perfect; good enough to never lose a paste to a
    /// formatting quirk.
    static func stripHTMLTags(_ html: String) -> String? {
        var s = html
        // Drop <script>...</script> and <style>...</style> contents whole.
        s = s.replacingOccurrences(of: "<script[\\s\\S]*?</script>",
                                   with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "<style[\\s\\S]*?</style>",
                                   with: " ", options: .regularExpression)
        // Block-level tags → newline so paragraphs survive.
        s = s.replacingOccurrences(of: "</(p|div|br|li|tr|h[1-6])[^>]*>",
                                   with: "\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<br[^>]*>", with: "\n",
                                   options: [.regularExpression, .caseInsensitive])
        // Strip remaining tags.
        s = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        // Decode the entities WhatsApp/Notes/Slack/email actually emit.
        let entities: [(String, String)] = [
            ("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&apos;", "'"), ("&#39;", "'"), ("&hellip;", "…"),
            ("&mdash;", "—"), ("&ndash;", "–"), ("&copy;", "©"), ("&reg;", "®"),
        ]
        for (e, r) in entities { s = s.replacingOccurrences(of: e, with: r) }
        // Numeric entities: &#123;
        s = s.replacingOccurrences(of: "&#(\\d+);", with: " ",
                                   options: .regularExpression) // crude, drops them; rare enough
        // Collapse repeated whitespace but PRESERVE newlines.
        s = s.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }


    func addItem(_ item: ClipboardItem) {
        if let first = items.first(where: { !$0.isPinned }),
           item.isDuplicate(of: first) { return }

        // Bug #2 — preserve V-cycle position across external pasteboard
        // writes.  Previously `selectedIndex = 0` at the end of this method
        // would snap the popup's highlight back to row 0 every time any app
        // (Universal Clipboard, Alfred, a browser extension) wrote to the
        // pasteboard mid-cycle.  Now: if the popup is visible, remember the
        // currently-highlighted item BY ID before the insert, then re-resolve
        // its new index after items updates.
        let preservedSelectionID: UUID? = previewWindow.isVisible
            ? (displayItems.indices.contains(selectedIndex) ? displayItems[selectedIndex].id : nil)
            : nil

        var item = item
        if item.sourceAppName == nil, let app = NSWorkspace.shared.frontmostApplication {
            item.sourceAppName = app.localizedName
            item.sourceBundleID = app.bundleIdentifier
        }

        // Compute diff badge before inserting (existing items are current ring)
        if case .text(let newText) = item.content {
            var mutableItem = item
            mutableItem.diffBadge = computeDiffBadge(newText: newText, against: items)
            items.insert(mutableItem, at: 0)
        } else {
            items.insert(item, at: 0)
        }

        let unpinned = items.indices.filter { !items[$0].isPinned }
        if unpinned.count > maxItems, let oldest = unpinned.last {
            evictFileSnapshots(for: items[oldest])
            items.remove(at: oldest)
            markBlobPurgeNeeded()
        }

        if let preservedSelectionID,
           let newIdx = displayItems.firstIndex(where: { $0.id == preservedSelectionID }) {
            selectedIndex = newIdx
        } else {
            selectedIndex = 0
        }

        // The freshly-captured item has embedding == nil, which is exactly
        // what recomputeEmbeddingsInBackground picks up — one shared code
        // path for ALL embedding computation (initial capture, post-load
        // backfill, post-OCR and post-note-edit refreshes) instead of the
        // hand-inlined duplicate of its vector→floats→main-hop dance that
        // used to live here and had already drifted once (it embedded the
        // bare textForEmbedding after the shared path moved to the richer
        // richEmbeddingText).
        recomputeEmbeddingsInBackground()

        // OCR for images; PDFKit text extraction for PDF-typed items.
        // Runs on a utility queue so it never blocks the main thread.
        if case .image(let nsImage, let rawData, let dataType) = item.content,
           item.ocrText == nil {
            let itemID = item.id
            let isPDF  = dataType.rawValue.lowercased().contains("pdf")
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self else { return }
                var extracted: String?
                if isPDF, let pdf = PDFDocument(data: rawData) {
                    // PDFKit text extraction — fast, no Vision needed.
                    let pages = (0..<pdf.pageCount).compactMap { pdf.page(at: $0)?.string }
                    let joined = pages.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !joined.isEmpty { extracted = joined }
                } else {
                    // Vision OCR for raster images (PNG, JPEG, HEIC, TIFF, WebP …).
                    // Decode FULL RESOLUTION from the raw bytes here — the
                    // item's stored NSImage is a ≤1024px ring thumbnail
                    // (ClipboardContent.imageContent), and OCR on a
                    // downsampled screenshot loses exactly the small text
                    // most worth extracting. Transient: this bitmap lives
                    // only for the duration of the request, off-main.
                    guard !dataType.rawValue.contains("gif"),
                          let cgImage = (NSImage(data: rawData) ?? nsImage)
                              .cgImage(forProposedRect: nil, context: nil, hints: nil)
                    else { return }
                    let req = VNRecognizeTextRequest()
                    req.recognitionLevel = .accurate
                    req.usesLanguageCorrection = true
                    try? VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([req])
                    let text = (req.results as? [VNRecognizedTextObservation] ?? [])
                        .compactMap { $0.topCandidates(1).first?.string }
                        .joined(separator: " ")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { extracted = text }
                }
                guard let ocrResult = extracted else { return }
                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          let idx = self.items.firstIndex(where: { $0.id == itemID }),
                          idx < self.items.count,
                          self.items[idx].ocrText == nil else { return }
                    // ocrText's didSet rebuilds the search haystacks itself.
                    self.items[idx].ocrText = ocrResult
                    // The embedding was computed at capture time, BEFORE this
                    // OCR finished — for an image that means it encodes only
                    // "image PNG 1024×768 pixels"-style metadata, which can
                    // never semantically match a related text note. Now that
                    // the real content text exists, wipe the stale vector and
                    // let recomputeEmbeddingsInBackground (which picks up
                    // every nil-embedding item) rebuild it from the full
                    // richEmbeddingText, OCR included.
                    self.items[idx].embedding = nil
                    self.recomputeEmbeddingsInBackground()
                }
            }
        }
    }

    func fetchURLTitle(for itemID: UUID, url: URL) {
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let self, let data,
                  let html = String(data: data, encoding: .utf8)
                          ?? String(data: data, encoding: .isoLatin1) else { return }
            guard let startRange = html.range(of: "<title", options: .caseInsensitive),
                  let gtIdx = html[startRange.upperBound...].firstIndex(of: ">"),
                  let endRange = html.range(of: "</title>", options: .caseInsensitive) else { return }
            let titleStart = html.index(after: gtIdx)
            guard titleStart < endRange.lowerBound else { return }
            let title = String(html[titleStart..<endRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .htmlDecoded
            guard !title.isEmpty else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      let idx = self.items.firstIndex(where: { $0.id == itemID }),
                      idx < self.items.count else { return }
                self.items[idx].urlTitle = title
                // The title is part of richEmbeddingText, but the embedding
                // was computed seconds ago, before this fetch returned — so
                // URL items' semantic fingerprints permanently lacked their
                // page title (OCR arrival re-embedded; title arrival forgot
                // to). Same wipe-and-refill every other late-arriving
                // enrichment uses.
                self.items[idx].embedding = nil
                self.lastSearchQuery = nil
                self.recomputeEmbeddingsInBackground()
            }
        }.resume()
    }

    // MARK: - Diff badge

    func computeDiffBadge(newText: String, against existing: [ClipboardItem]) -> String? {
        // Runs synchronously on the capture path against up to 10 prior items —
        // line-splitting a multi-megabyte paste (a big log/CSV/source file) here
        // would stall the main thread. The diff badge is a nicety for
        // human-scale edits, so cap the text considered.
        guard newText.count <= Self.maxDiffBadgeTextLength else { return nil }
        let newLines = newText.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard newLines.count >= 2 else { return nil }   // single-line: skip
        let newSet = Set(newLines)

        for (i, item) in existing.prefix(10).enumerated() {
            guard let existText = item.textForEmbedding,
                  existText.count <= Self.maxDiffBadgeTextLength else { continue }
            let existLines = existText.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard existLines.count >= 2 else { continue }
            let existSet = Set(existLines)

            let shared = newSet.intersection(existSet).count
            let total  = newSet.union(existSet).count
            guard total > 0 else { continue }
            let similarity = Double(shared) / Double(total)
            guard similarity >= 0.4 && similarity < 1.0 else { continue }

            let added   = newSet.subtracting(existSet).count
            let removed = existSet.subtracting(newSet).count
            guard added + removed > 0 else { continue }

            var parts: [String] = []
            if added   > 0 { parts.append("+\(added)") }
            if removed > 0 { parts.append("-\(removed)") }
            return parts.joined(separator: " ") + " from #\(i + 2)"
        }
        return nil
    }


}
