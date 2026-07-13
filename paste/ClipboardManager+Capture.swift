import AppKit
import SwiftUI
import Vision
import NaturalLanguage
@preconcurrency import PDFKit

extension ClipboardManager {

    func startPolling() {
        lastChangeCount = NSPasteboard.general.changeCount
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
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

        if !remoteClipboardDataReady(pb) {
            remoteClipboardRetryCount += 1
            if remoteClipboardRetryCount < Self.maxRemoteClipboardRetries {
                return
            }
            remoteClipboardLastFileSize.removeAll()
        }
        remoteClipboardRetryCount = 0
        lastChangeCount = pb.changeCount

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
                        self.addCaptured(ClipboardItem(content: .rtfd(rtfdData, plain: attrStr.string)), sidecar: sidecarSnapshot)
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
                if let fallback { addCaptured(fallback, sidecar: sidecarSnapshot) }
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
            addCaptured(item, sidecar: sidecarSnapshot)
        } else {
            AuthManager.shared.registerActionUsage(actionID: "fail.capture")
        }
    }

    static let remoteClipboardMarker = NSPasteboard.PasteboardType("com.apple.is-remote-clipboard")

    func remoteClipboardDataReady(_ pb: NSPasteboard) -> Bool {
        guard let types = pb.types, types.contains(Self.remoteClipboardMarker) else { return true }
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
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
        if let s = pb.string(forType: .string), !s.isEmpty { return true }
        for t in types where t != Self.remoteClipboardMarker {
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
        case .richText:
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
        s = s.replacingOccurrences(of: "<br[^>]*>", with: "\n",
                                   options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let entities: [(String, String)] = [
            ("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&apos;", "'"), ("&#39;", "'"), ("&hellip;", "…"),
            ("&mdash;", "—"), ("&ndash;", "–"), ("&copy;", "©"), ("&reg;", "®"),
        ]
        for (e, r) in entities { s = s.replacingOccurrences(of: e, with: r) }
        s = s.replacingOccurrences(of: "&#(\\d+);", with: " ",
                                   options: .regularExpression)
        s = s.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
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

    func computeDiffBadge(newText: String, against existing: [ClipboardItem]) -> String? {
        guard newText.count <= Self.maxDiffBadgeTextLength else { return nil }
        let newLines = newText.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard newLines.count >= 2 else { return nil }
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
