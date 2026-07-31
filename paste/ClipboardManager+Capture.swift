import AppKit
import SwiftUI
import Vision
import NaturalLanguage
@preconcurrency import PDFKit

extension ClipboardManager {

    func startPolling() {
        lastChangeCount = NSPasteboard.general.changeCount
        // Poll fast (100ms) so a copy is noticed almost immediately and two
        // quick copies in a row aren't collapsed into one missed capture. The
        // idle check is just an integer compare, so a tight interval is cheap;
        // the actual (heavy) capture work runs off the main thread — see
        // pollClipboard / processCapturedPasteboard.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.pollClipboard()
        }
        RunLoop.main.add(pollTimer!, forMode: .common)
    }

    func pollClipboard() {
        guard !isCapturingPaused else { return }

        guard !isSimulatingPaste else { return }
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }

        if Self.pasteboardIsConcealed(pb) {
            lastChangeCount = pb.changeCount
            return
        }

        // App-level exclusion — a coarser, user-managed safety net alongside
        // the concealed-type check above, for sources (e.g. a browser on a
        // banking page) that never mark their own copies as sensitive.
        if let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           excludedCaptureBundleIDs.contains(bundleID) {
            lastChangeCount = pb.changeCount
            return
        }

        if !pasteboardDataReady(pb) {
            remoteClipboardRetryCount += 1
            if remoteClipboardRetryCount < Self.maxRemoteClipboardRetries {
                return
            }
            remoteClipboardLastFileSize.removeAll()
        }
        remoteClipboardRetryCount = 0
        lastChangeCount = pb.changeCount

        // Hand the heavy half (reading every representation + content detection)
        // to a serial background queue. The copy is already "claimed" above
        // (lastChangeCount advanced), so the main thread returns instantly and
        // the actual work never blocks the UI or the next poll.
        captureQueue.async { [weak self] in self?.processCapturedPasteboard(pb) }
    }

    /// Heavy half of capture — runs OFF the main thread (on `captureQueue`).
    /// Reads every pasteboard representation, builds the item (which runs
    /// content detection), and hops back to the main thread only to insert.
    func processCapturedPasteboard(_ pb: NSPasteboard) {
        let sidecarSnapshot = Self.allPasteboardTypes(from: pb)

        if captureFiles {
            let urls = fileURLs(from: pb)
            if !urls.isEmpty {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let snapshots = FileSnapshotStore.snapshot(urls)
                guard !snapshots.isEmpty else { return }
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.addCaptured(ClipboardItem(content: snapshots.count == 1
                        ? .file(snapshots[0]) : .files(snapshots)), sidecar: sidecarSnapshot)
                }
            }
            return
            }

            if resolvePromisedFiles(from: pb) { return }
        }

        if captureRichText, let rtfdData = pb.data(forType: .rtfd) {
            let fallback = basicItem(from: pb)
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { return }
                let attrStr = NSAttributedString(rtfd: rtfdData, documentAttributes: nil)
                DispatchQueue.main.async {
                    if let attrStr, !attrStr.string.isEmpty {
                        // A table's cells are separate paragraphs in `.string`
                        // with no column-boundary character — reading it raw
                        // collapses every copied table (Pages/Numbers/Mail/
                        // TextEdit) into one column. Tab-separate real table
                        // rows; fall back to the raw string otherwise.
                        let plainText = TableCellExtractor.tabSeparatedPlainText(from: attrStr) ?? attrStr.string
                        if Self.isImageOnlyAttributedString(attrStr) {
                            if case .image = fallback?.content {
                                self.addCaptured(fallback!, sidecar: sidecarSnapshot)
                            } else if let extracted = Self.imageItem(fromAttachmentIn: attrStr) {
                                self.addCaptured(extracted, sidecar: sidecarSnapshot)
                            } else {
                                self.addCaptured(ClipboardItem(content: .rtfd(rtfdData, plain: plainText)), sidecar: sidecarSnapshot)
                            }
                        } else {
                            self.addCaptured(ClipboardItem(content: .rtfd(rtfdData, plain: plainText)), sidecar: sidecarSnapshot)
                        }
                    } else if let fallback {
                        self.addCaptured(fallback, sidecar: sidecarSnapshot)
                    }
                }
            }
            return
        }

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
            let fallback = basicItem(from: pb)
            if case .image = fallback?.content, Self.isImageOnlyHTML(html) {
                if let fallback {
                    DispatchQueue.main.async { [weak self] in
                        self?.addCaptured(fallback, sidecar: sidecarSnapshot)
                    }
                }
                return
            }
            let pasteboardPlain = pb.string(forType: .string)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let htmlMustSurvive = Self.htmlContainsTable(html) || Self.htmlContainsImage(html)
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { return }
                let plain = Self.plainText(fromHTML: htmlData)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                DispatchQueue.main.async {
                    if let plain, !plain.isEmpty {
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

        if captureRichText, let rtfData = pb.data(forType: .rtf) {
            let fallback = basicItem(from: pb)
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { return }
                let attrStr = NSAttributedString(rtf: rtfData, documentAttributes: nil)
                let rtfdUpgrade: Data? = {
                    guard let attrStr, attrStr.containsAttachments else { return nil }
                    let range = NSRange(location: 0, length: attrStr.length)
                    return try? attrStr.data(from: range,
                                             documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
                }()
                DispatchQueue.main.async {
                    if let attrStr, !attrStr.string.isEmpty {
                        // Same table-collapse risk as the RTFD path above.
                        let plainText = TableCellExtractor.tabSeparatedPlainText(from: attrStr) ?? attrStr.string
                        if Self.isImageOnlyAttributedString(attrStr) {
                            if case .image = fallback?.content {
                                self.addCaptured(fallback!, sidecar: sidecarSnapshot)
                            } else if let extracted = Self.imageItem(fromAttachmentIn: attrStr) {
                                self.addCaptured(extracted, sidecar: sidecarSnapshot)
                            } else if let rtfdUpgrade {
                                self.addCaptured(ClipboardItem(content: .rtfd(rtfdUpgrade, plain: plainText)), sidecar: sidecarSnapshot)
                            } else {
                                self.addCaptured(ClipboardItem(content: .richText(attrStr, plain: plainText)), sidecar: sidecarSnapshot)
                            }
                        } else if let rtfdUpgrade {
                            self.addCaptured(ClipboardItem(content: .rtfd(rtfdUpgrade, plain: plainText)), sidecar: sidecarSnapshot)
                        } else {
                            self.addCaptured(ClipboardItem(content: .richText(attrStr, plain: plainText)), sidecar: sidecarSnapshot)
                        }
                    } else if let fallback {
                        self.addCaptured(fallback, sidecar: sidecarSnapshot)
                    }
                }
            }
            return
        }

        if let str = pb.string(forType: .string), !str.isEmpty {
            let sidecar = sidecarSnapshot
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { return }
                let item = ClipboardItem(content: .text(str))
                DispatchQueue.main.async {
                    self.addCaptured(item, sidecar: sidecar)
                    if self.fetchURLTitles {
                        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
                        if let url = URL(string: trimmed),
                           url.scheme == "http" || url.scheme == "https" {
                            self.fetchURLTitle(for: item.id, url: url)
                        }
                    }
                }
            }
            return
        }

        if let item = basicItem(from: pb) {
            DispatchQueue.main.async { [weak self] in
                self?.addCaptured(item, sidecar: sidecarSnapshot)
            }
        } else if !(pb.types ?? []).isEmpty {
            // basicItem() already falls back to wrapping ANY non-empty type
            // as `.blob`, so reaching here with real types present means
            // something genuinely couldn't be read — worth knowing about.
            // But when `pb.types` itself is empty, nothing was ever offered
            // (some apps momentarily declare-then-clear, or write only a
            // concealed marker with no payload) — that's not a capture
            // failure, there was nothing to capture, and logging it just
            // buried the rare, real gaps in type coverage under noise.
            DispatchQueue.main.async {
                AuthManager.shared.registerActionUsage(actionID: "fail.capture")
            }
        }
    }

    static let remoteClipboardMarker = NSPasteboard.PasteboardType("com.apple.is-remote-clipboard")

    /// True once at least one declared pasteboard type actually has bytes
    /// behind it — not just once the type NAME is announced. A source can
    /// declare types before the payload exists: Continuity/Universal
    /// Clipboard (a copy made on another Apple device) announces itself
    /// immediately while the real transfer is still in flight, and — the
    /// same race, different cause — Photos.app copying an iCloud-only photo,
    /// or Finder copying an iCloud Drive file that hasn't downloaded locally,
    /// declares its types up front while iCloud fetches the actual bytes in
    /// the background. Reading on the very next 100ms poll used to see
    /// "types present, no data yet" as a genuine failure and fall straight
    /// into the "Private clipboard data" blob catch-all — this is the retry
    /// gate `pollClipboard` uses (`Self.maxRemoteClipboardRetries`, ~9s
    /// budget) so that download has time to actually finish first.
    func pasteboardDataReady(_ pb: NSPasteboard) -> Bool {
        guard let types = pb.types, !types.isEmpty else { return true }

        // Continuity/Universal Clipboard specifically rewrites a growing
        // file promise as the transfer completes — file-size stability
        // (not just non-empty data) is the only reliable "done" signal.
        if types.contains(Self.remoteClipboardMarker),
           let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            var allStable = true
            for url in urls {
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                let key = url.path
                let previous = remoteClipboardLastFileSize[key]
                remoteClipboardLastFileSize[key] = size
                if size == 0 || previous != size {
                    allStable = false
                }
            }
            if allStable {
                for url in urls { remoteClipboardLastFileSize.removeValue(forKey: url.path) }
            }
            return allStable
        }

        // General case: at least one declared type must actually have data.
        for t in types {
            if let data = pb.data(forType: t), !data.isEmpty { return true }
        }
        return false
    }

    static let concealedPasteboardTypes: Set<String> = [
        "org.nspasteboard.ConcealedType",
        "org.nspasteboard.TransientType",
        "org.nspasteboard.AutoGeneratedType",
    ]

    static func pasteboardIsConcealed(_ pb: NSPasteboard) -> Bool {
        guard let types = pb.types else { return false }
        for t in types where concealedPasteboardTypes.contains(t.rawValue) { return true }
        return false
    }

    static func allPasteboardTypes(from pb: NSPasteboard) -> [String: Data] {
        var map: [String: Data] = [:]
        for t in pb.types ?? [] {
            if let data = pb.data(forType: t), !data.isEmpty, data.count < Self.maxDataBytes {
                map[t.rawValue] = data
            }
        }
        return map
    }

    func addCaptured(_ item: ClipboardItem, sidecar: [String: Data]) {
        var enriched = item
        enriched.sidecarTypes = Self.prunedSidecar(sidecar, for: item.content)
        AuthManager.shared.registerActionUsage(actionID: "capture.\(item.primaryTag.folderName)")
        addItem(enriched)
    }

    static func prunedSidecar(_ all: [String: Data],
                                      for content: ClipboardContent) -> [String: Data]? {
        if case .blob = content { return nil }
        var excluded: Set<String> = [
            "public.utf8-plain-text", "public.plain-text",
            "public.utf16-external-plain-text", "NSStringPboardType",
        ]
        switch content {
        case .richText(let attrStr, _):
            excluded.formUnion(["NSRTFPboardType"])
            // Same reasoning as the .rtfd case: an image-bearing attributed
            // string must not carry a stale "public.rtf" sidecar forward —
            // the write path builds RTFD on the fly for these, and a plain
            // .rtf re-attached here would just be a competing image-less copy.
            if attrStr.containsAttachments {
                excluded.formUnion(["public.rtf"])
            }
        case .rtfd:
            // Source apps (Notes especially) often put HTML on the pasteboard
            // alongside RTFD for the same copy — text-only or referencing an
            // image the source app can resolve but nothing else can. Since
            // RTFD already carries the real image, that HTML must never ride
            // along as a sidecar: some destination apps (WebKit/HTML-first
            // paste handling) prefer public.html over public.rtfd when both
            // are present, silently pasting the image-less alternative.
            excluded.formUnion(["com.apple.flat-rtfd", "NSRTFDPboardType",
                                "public.rtf", "NSRTFPboardType",
                                "public.html", "Apple HTML pasteboard type"])
        case .html:
            excluded.formUnion(["public.html", "Apple HTML pasteboard type"])
        case .image(_, _, let dataType):
            excluded.formUnion([dataType.rawValue, "public.tiff", "NSTIFFPboardType"])
        case .svg:
            excluded.formUnion(["public.svg-image", "com.adobe.illustrator.svg", "org.w3.svg"])
        case .file, .files:
            excluded.formUnion(["public.file-url", "NSFilenamesPboardType"])
        case .text, .blob, .group:
            break
        }
        let pruned = all.filter { !excluded.contains($0.key) }
        return pruned.isEmpty ? nil : pruned
    }

    func basicItem(from pb: NSPasteboard) -> ClipboardItem? {
        if let str = pb.string(forType: .string), !str.isEmpty {
            return ClipboardItem(content: .text(str))
        }

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

        let imageTypes: [NSPasteboard.PasteboardType] = [
            .init("public.png"), .tiff,
            .init("com.adobe.pdf"), .init("public.jpeg"), .init("public.heic"),
            .init("com.compuserve.gif"), .init("public.gif")
        ]
        for type in imageTypes {
            if let data = pb.data(forType: type), let img = NSImage(data: data) {
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

    func resolvePromisedFiles(from pb: NSPasteboard) -> Bool {
        guard let receivers = pb.readObjects(
            forClasses: [NSFilePromiseReceiver.self],
            options: nil
        ) as? [NSFilePromiseReceiver], !receivers.isEmpty else { return false }

        let destDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipenPromises/\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

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

    static func isImageOnlyHTML(_ html: String) -> Bool {
        guard html.range(of: "<img", options: .caseInsensitive) != nil else { return false }
        let text = stripHTMLTags(html)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty
    }

    /// Notes/Pages/Mail/TextEdit represent a copied image as an RTF(D)
    /// attributed string with an `NSTextAttachment` run — the "plain text"
    /// for that run is just the Unicode object-replacement character, never
    /// truly empty, so a plain `.isEmpty` check on `attrStr.string` doesn't
    /// catch it. Strip that placeholder out before judging whether there's
    /// any real text alongside the image.
    static func isImageOnlyAttributedString(_ attrStr: NSAttributedString) -> Bool {
        guard attrStr.containsAttachments else { return false }
        let stripped = attrStr.string
            .replacingOccurrences(of: "\u{FFFC}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.isEmpty
    }

    /// Pulls the actual image out of an `NSTextAttachment` embedded in an
    /// image-only attributed string, for apps (Notes and similar rich-text
    /// editors) that put the picture ONLY inside the RTFD attachment and
    /// don't also duplicate it as a raw public.png/tiff pasteboard type —
    /// `basicItem(from:)`'s image-type scan finds nothing in that case, so
    /// without this the item would fall back to being captured as .rtfd
    /// with no visible image at all.
    static func imageItem(fromAttachmentIn attrStr: NSAttributedString) -> ClipboardItem? {
        var found: ClipboardItem?
        let full = NSRange(location: 0, length: attrStr.length)
        attrStr.enumerateAttribute(.attachment, in: full, options: []) { value, _, stop in
            guard found == nil, let attachment = value as? NSTextAttachment else { return }
            if let wrapperData = attachment.fileWrapper?.regularFileContents,
               let img = NSImage(data: wrapperData),
               let content = ClipboardContent.imageContent(rawData: wrapperData,
                                                            dataType: .init("public.png"), fallback: img) {
                found = ClipboardItem(content: content)
                stop.pointee = true
                return
            }
            if let img = attachment.image, let data = img.pngData(),
               let content = ClipboardContent.imageContent(rawData: data,
                                                            dataType: .init("public.png"), fallback: img) {
                found = ClipboardItem(content: content)
                stop.pointee = true
            }
        }
        return found
    }

    static func htmlContainsTable(_ html: String) -> Bool {
        html.range(of: "<table", options: .caseInsensitive) != nil
    }

    static func htmlContainsImage(_ html: String) -> Bool {
        html.range(of: "<img", options: .caseInsensitive) != nil
    }

    static func plainText(fromHTML data: Data) -> String? {
        let raw: String? = String(data: data, encoding: .utf8)
                       ?? String(data: data, encoding: .utf16)
                       ?? String(data: data, encoding: .utf16BigEndian)
                       ?? String(data: data, encoding: .utf16LittleEndian)
                       ?? String(data: data, encoding: .isoLatin1)
                       ?? String(data: data, encoding: .ascii)
        guard let html = raw, !html.isEmpty else { return nil }
        return stripHTMLTags(html)
    }

    static func stripHTMLTags(_ html: String) -> String? {
        var s = html
        s = s.replacingOccurrences(of: "<script[\\s\\S]*?</script>",
                                   with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "<style[\\s\\S]*?</style>",
                                   with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "</(p|div|br|li|tr|h[1-6])[^>]*>",
                                   with: "\n", options: [.regularExpression, .caseInsensitive])
        // Table cells: `<td>`/`<th>` boundaries become tabs so a multi-column
        // row survives as tab-separated plain text — the same convention
        // Excel/Sheets/TextEdit use, and what lets a spreadsheet app read the
        // column structure back on paste. Without this, the generic tag-to-
        // space catchall below swallows every cell boundary, so a
        // multi-column "paste without formatting" lands as a single column.
        s = s.replacingOccurrences(of: "<t[dh][^>]*>", with: "",
                                   options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "</t[dh][^>]*>", with: "\t",
                                   options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<br[^>]*>", with: "\n",
                                   options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        // The last cell in a row leaves a dangling tab before the newline
        // </tr> produced above — drop it so rows don't end in an empty
        // phantom column.
        s = s.replacingOccurrences(of: "\t\n", with: "\n")
        let entities: [(String, String)] = [
            ("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&apos;", "'"), ("&#39;", "'"), ("&hellip;", "…"),
            ("&mdash;", "—"), ("&ndash;", "–"), ("&copy;", "©"), ("&reg;", "®"),
        ]
        for (e, r) in entities { s = s.replacingOccurrences(of: e, with: r) }
        s = s.replacingOccurrences(of: "&#(\\d+);", with: " ",
                                   options: .regularExpression)
        // Collapse repeated plain spaces only — NOT tabs, which is exactly
        // the character the table-cell substitution above relies on to mark
        // column boundaries.
        s = s.replacingOccurrences(of: " +", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func addItem(_ item: ClipboardItem) {
        if let first = items.first(where: { !$0.isPinned }),
           item.isDuplicate(of: first) { return }

        let preservedSelectionID: UUID? = previewWindow.isVisible
            ? (displayItems.indices.contains(selectedIndex) ? displayItems[selectedIndex].id : nil)
            : nil

        var item = item
        if item.sourceAppName == nil, let app = NSWorkspace.shared.frontmostApplication {
            item.sourceAppName = app.localizedName
            item.sourceBundleID = app.bundleIdentifier
        }
        // Stamp the clip with whichever collection is active as it's captured.
        // In the "All" view nothing is active, so the clip stays unfiled — it
        // shows in All and in no collection until filed with a transform.
        if item.collections.isEmpty, let activeCollection {
            item.collections = [activeCollection]
        }

        if case .text(let newText) = item.content {
            var mutableItem = item
            if let (badge, detail) = computeDiffBadge(newText: newText, against: items) {
                mutableItem.diffBadge = badge
                mutableItem.diffDetail = detail
            }
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

        recomputeEmbeddingsInBackground()

        if case .image(let nsImage, let rawData, let dataType) = item.content,
           item.ocrText == nil {
            let itemID = item.id
            let isPDF  = dataType.rawValue.lowercased().contains("pdf")
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self else { return }
                var extracted: String?
                if isPDF, let pdf = PDFDocument(data: rawData) {
                    let pages = (0..<pdf.pageCount).compactMap { pdf.page(at: $0)?.string }
                    let joined = pages.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !joined.isEmpty { extracted = joined }
                } else {
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
                    self.items[idx].ocrText = ocrResult
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
                self.items[idx].embedding = nil
                self.lastSearchQuery = nil
                self.recomputeEmbeddingsInBackground()
            }
        }.resume()
    }

    private static let maxDiffDetailItems = 8

    func computeDiffBadge(newText: String, against existing: [ClipboardItem]) -> (badge: String, detail: DiffDetail)? {
        guard newText.count <= Self.maxDiffBadgeTextLength else { return nil }
        let newLines = newText.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        if newLines.count >= 2 {
            return lineDiffBadge(newLines: newLines, against: existing)
        }
        // Single-line text (e.g. a short note or title) can't be diffed
        // line-by-line — fall back to word-level comparison instead, gated
        // at a much stricter 80% similarity so unrelated short strings never
        // get flagged as "the same item with edits".
        return wordDiffBadge(newText: newText, against: existing)
    }

    private func lineDiffBadge(newLines: [String], against existing: [ClipboardItem]) -> (badge: String, detail: DiffDetail)? {
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

            // Preserve original order of the added/removed lines, capped.
            let addedLines   = newLines.filter   { !existSet.contains($0) }
            let removedLines = existLines.filter { !newSet.contains($0) }
            guard !addedLines.isEmpty || !removedLines.isEmpty else { continue }

            let rank = i + 2
            var parts: [String] = []
            if !addedLines.isEmpty   { parts.append("+\(addedLines.count)") }
            if !removedLines.isEmpty { parts.append("-\(removedLines.count)") }
            let badge = parts.joined(separator: " ") + " from #\(rank)"
            let detail = DiffDetail(added: Array(addedLines.prefix(Self.maxDiffDetailItems)),
                                    removed: Array(removedLines.prefix(Self.maxDiffDetailItems)),
                                    fromRank: rank)
            return (badge, detail)
        }
        return nil
    }

    private func wordDiffBadge(newText: String, against existing: [ClipboardItem]) -> (badge: String, detail: DiffDetail)? {
        let newWords = newText.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard newWords.count >= 2 else { return nil }
        let newSet = Set(newWords.map { $0.lowercased() })

        for (i, item) in existing.prefix(10).enumerated() {
            guard let existText = item.textForEmbedding,
                  existText.count <= Self.maxDiffBadgeTextLength else { continue }
            let existLines = existText.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard existLines.count < 2 else { continue }  // compare only against other single-line texts
            let existWords = existText.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard existWords.count >= 2 else { continue }
            let existSet = Set(existWords.map { $0.lowercased() })

            let shared = newSet.intersection(existSet).count
            let total  = newSet.union(existSet).count
            guard total > 0 else { continue }
            let similarity = Double(shared) / Double(total)
            guard similarity >= 0.8 && similarity < 1.0 else { continue }

            let addedWords   = newWords.filter { !existSet.contains($0.lowercased()) }
            let removedWords = existWords.filter { !newSet.contains($0.lowercased()) }
            guard !addedWords.isEmpty || !removedWords.isEmpty else { continue }

            let rank = i + 2
            var parts: [String] = []
            if !addedWords.isEmpty   { parts.append("+" + addedWords.joined(separator: " ")) }
            if !removedWords.isEmpty { parts.append("-" + removedWords.joined(separator: " ")) }
            let badge = parts.joined(separator: " ") + " from #\(rank)"
            let detail = DiffDetail(added: Array(addedWords.prefix(Self.maxDiffDetailItems)),
                                    removed: Array(removedWords.prefix(Self.maxDiffDetailItems)),
                                    fromRank: rank)
            return (badge, detail)
        }
        return nil
    }

}
