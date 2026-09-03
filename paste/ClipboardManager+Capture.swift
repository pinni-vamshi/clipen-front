import AppKit
import SwiftUI
import Vision
import NaturalLanguage
import ImageIO
@preconcurrency import PDFKit

extension ClipboardManager {

    static let pollIntervalActive: TimeInterval = 0.1
    static let pollIntervalIdle: TimeInterval = 0.5
    static let pollIdleThreshold: TimeInterval = 60

    func startPolling() {
        lastChangeCount = NSPasteboard.general.changeCount
        lastPollActivityAt = Date()
        scheduleNextPoll()
    }

    private func scheduleNextPoll() {
        let idleFor = Date().timeIntervalSince(lastPollActivityAt)
        let interval = idleFor > Self.pollIdleThreshold ? Self.pollIntervalIdle : Self.pollIntervalActive
        pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.pollClipboard()
            self.scheduleNextPoll()
        }
        RunLoop.main.add(pollTimer!, forMode: .common)
    }

    func pollClipboard() {

        purgeUncapturedPlaceholderIfSuperseded()

        guard !isCapturingPaused else { return }

        guard !isSimulatingPaste else { return }
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastPollActivityAt = Date()

        if Self.pasteboardIsConcealed(pb) {
            lastChangeCount = pb.changeCount
            addUncapturedPlaceholder(
                reason: String(localized: "Not captured — pastes with system default"),
                changeCount: pb.changeCount)
            return
        }

        if let frontmost = NSWorkspace.shared.frontmostApplication,
           let bundleID = frontmost.bundleIdentifier,
           excludedCaptureBundleIDs.contains(bundleID) {
            lastChangeCount = pb.changeCount
            let appName = frontmost.localizedName ?? "This app"
            CopyFeedbackPanel.shared.show(message: "\(appName) is excluded from copying")
            addUncapturedPlaceholder(
                reason: String(localized: "Not captured — pastes with system default"),
                changeCount: pb.changeCount)
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

        let generationBefore = captureAttemptGeneration
        let changeCountAtAttempt = pb.changeCount
        captureQueue.async { [weak self] in
            self?.processCapturedPasteboard(pb)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                guard let self, self.captureAttemptGeneration == generationBefore else { return }
                CopyFeedbackPanel.shared.show()
                self.addUncapturedPlaceholder(
                    reason: String(localized: "Not captured — pastes with system default"),
                    changeCount: changeCountAtAttempt)
            }
        }
    }

    func processCapturedPasteboard(_ pb: NSPasteboard) {
        let sidecarSnapshot = Self.allPasteboardTypes(from: pb)

        if captureFiles {
            let urls = fileURLs(from: pb)
            if !urls.isEmpty {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let snapshots = FileSnapshotStore.snapshot(urls)
                guard !snapshots.isEmpty else {
                    DispatchQueue.main.async { CopyFeedbackPanel.shared.show() }
                    return
                }
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

        let htmlCandidate = Self.readHTML(from: pb)
        let htmlIsSubstantial = htmlCandidate.map {
            Self.htmlContainsTable($0.html) || Self.htmlContainsImage($0.html)
                || Self.htmlContainsInlineFormatting($0.html)
        } ?? false

        if captureRichText, !htmlIsSubstantial, let rtfdData = pb.data(forType: .rtfd) {
            let fallback = basicItem(from: pb)
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { return }
                let attrStr = NSAttributedString(rtfd: rtfdData, documentAttributes: nil)
                DispatchQueue.main.async {
                    if let attrStr, !attrStr.string.isEmpty {

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
                    } else {
                        CopyFeedbackPanel.shared.show()
                    }
                }
            }
            return
        }

        if let (_, htmlData, html) = htmlCandidate {
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
            let htmlMustSurvive = htmlIsSubstantial
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
                    } else {
                        CopyFeedbackPanel.shared.show()
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
                    } else {
                        CopyFeedbackPanel.shared.show()
                    }
                }
            }
            return
        }

        if let str = pb.string(forType: .string), !str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
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

            let ccAtFailure = pb.changeCount
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self else { return }
                let pb = NSPasteboard.general
                guard pb.changeCount == ccAtFailure else { return }
                if let retryItem = self.basicItem(from: pb) {
                    DispatchQueue.main.async {
                        self.addCaptured(retryItem, sidecar: sidecarSnapshot)
                    }
                } else {
                    let typeList = pb.types?.map(\.rawValue) ?? []
                    let typesPresent = typeList.isEmpty ? "none" : typeList.joined(separator: ",")
                    let sourceKind = Self.captureFailureSourceKind(from: typeList)
                    DispatchQueue.main.async {
                        CopyFeedbackPanel.shared.show()
                        let sourceApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"
                        AuthManager.shared.registerActionUsage(
                            actionID: "fail.capture", value: typesPresent,
                            extraProperties: [
                                "type_count": typeList.count,
                                "source_kind": sourceKind,
                                "source_app": sourceApp,
                            ])
                    }
                }
            }
        }
    }

    /// A cheap, client-side classification of a capture failure's pasteboard
    /// types — turns "eyeball the raw comma-joined type string in `value`"
    /// into an actual PostHog breakdown-by-property (source_kind), without
    /// needing a server-side aggregation to see which browsers/apps are
    /// producing unreadable copies.
    static func captureFailureSourceKind(from types: [String]) -> String {
        if types.contains(where: { $0.hasPrefix("org.chromium") }) { return "chromium" }
        if types.contains(where: { $0.hasPrefix("com.apple.WebKit") }) { return "webkit" }
        if types.contains(where: { $0.hasPrefix("com.apple.AnnotationKit") }) { return "annotation" }
        if types.contains(where: { $0.hasPrefix("com.gingerlabs.Notability") }) { return "notability" }
        if types.contains(remoteClipboardMarker.rawValue) { return "remote_clipboard" }
        return "other"
    }

    static let remoteClipboardMarker = NSPasteboard.PasteboardType("com.apple.is-remote-clipboard")

    func pasteboardDataReady(_ pb: NSPasteboard) -> Bool {
        guard let types = pb.types, !types.isEmpty else { return true }

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

        // Ordinary (non-remote-clipboard) copy: don't fetch every advertised
        // type's full data just to prove SOME type is non-empty.
        // pb.data(forType:) materializes the entire representation over IPC
        // to the pasteboard server — for a source app that advertises a
        // full-size image or a large RTFD blob as its richest type, that
        // used to run unconditionally on the MAIN thread (the same run loop
        // the CGEventTap lives on) on every single capture, discarding the
        // result immediately after. In practice a source app that just
        // bumped changeCount and advertised types always has real data
        // behind at least one of them; the rare genuine-empty-pasteboard
        // case is still caught one poll tick later by
        // processCapturedPasteboard's own classification and last-resort
        // retry — this check only ever needed to matter for the
        // remote-clipboard-file case handled above, which uses a cheap
        // filesystem stat instead of a pasteboard data fetch.
        return true
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
        if let sourceApp = item.sourceAppName ?? NSWorkspace.shared.frontmostApplication?.localizedName {
            AuthManager.shared.registerActionUsage(actionID: "action.copy-from-app", value: sourceApp)
        }
        addItem(enriched)
    }

    static func prunedSidecar(_ all: [String: Data],
                                      for content: ClipboardContent) -> [String: Data]? {
        if case .blob = content { return nil }
        var excluded: Set<String> = [
            "public.utf8-plain-text", "public.plain-text",
            "public.utf16-external-plain-text", "NSStringPboardType",

            "public.tiff", "NSTIFFPboardType",
        ]
        switch content {
        case .richText(let attrStr, _):
            excluded.formUnion(["NSRTFPboardType"])

            if attrStr.containsAttachments {
                excluded.formUnion(["public.rtf"])
            }
        case .rtfd:

            excluded.formUnion(["com.apple.flat-rtfd", "NSRTFDPboardType",
                                "public.rtf", "NSRTFPboardType",
                                "public.html", "Apple HTML pasteboard type"])
        case .html:

            excluded.formUnion(["public.html", "Apple HTML pasteboard type"])
        case .image(_, _, let dataType):
            excluded.formUnion([dataType.rawValue])
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

        if let str = pb.string(forType: .string), !str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
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

        if let extracted = Self.imageFromUIKitArchive(pb) {
            return ClipboardItem(content: extracted)
        }

        if let data = pb.data(forType: ImageService.webpPasteboardType),
           let img = ImageService.decodeWebP(data: data),
           let content = ClipboardContent.imageContent(rawData: data, dataType: ImageService.webpPasteboardType,
                                                        fallback: img) {
            return ClipboardItem(content: content)
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

        for type in pb.types ?? [] {
            guard let data = pb.data(forType: type), !data.isEmpty else { continue }
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  CGImageSourceGetCount(source) > 0,
                  let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
            let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            if let content = ClipboardContent.imageContent(rawData: data, dataType: type, fallback: img) {
                return ClipboardItem(content: content)
            }
        }

        return nil
    }

    static func imageFromUIKitArchive(_ pb: NSPasteboard) -> ClipboardContent? {
        guard let data = pb.data(forType: .init("com.apple.uikit.image")),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let objects = plist["$objects"] as? [Any],
              let imgDict = objects.compactMap({ $0 as? [String: Any] }).first(where: { $0["UIImageData"] != nil }),
              let uid = imgDict["UIImageData"],
              let match = "\(uid)".range(of: #"value = (\d+)"#, options: .regularExpression),
              let index = Int("\(uid)"[match].replacingOccurrences(of: "value = ", with: "")),
              objects.indices.contains(index),
              let imgData = objects[index] as? Data,
              let img = NSImage(data: imgData)
        else { return nil }

        let isJPEG = imgData.starts(with: [0xFF, 0xD8, 0xFF])
        let dataType = NSPasteboard.PasteboardType(isJPEG ? "public.jpeg" : "public.png")
        return ClipboardContent.imageContent(rawData: imgData, dataType: dataType, fallback: img)
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
            guard !existing.isEmpty else {
                CopyFeedbackPanel.shared.show()
                return
            }
            let snapshots = FileSnapshotStore.snapshot(existing)
            guard !snapshots.isEmpty else {
                CopyFeedbackPanel.shared.show()
                return
            }
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

    static func isImageOnlyAttributedString(_ attrStr: NSAttributedString) -> Bool {
        guard attrStr.containsAttachments else { return false }
        let stripped = attrStr.string
            .replacingOccurrences(of: "\u{FFFC}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.isEmpty
    }

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

    static let htmlPasteboardTypes: [NSPasteboard.PasteboardType] = [
        .init("public.html"),
        .init("Apple HTML pasteboard type")
    ]

    static func readHTML(from pb: NSPasteboard) -> (type: NSPasteboard.PasteboardType, data: Data, html: String)? {
        for type in htmlPasteboardTypes {
            guard let htmlData = pb.data(forType: type) else { continue }
            let html: String? = String(data: htmlData, encoding: .utf8)
                ?? String(data: htmlData, encoding: .utf16)
                ?? String(data: htmlData, encoding: .utf16BigEndian)
                ?? String(data: htmlData, encoding: .utf16LittleEndian)
                ?? String(data: htmlData, encoding: .isoLatin1)
                ?? String(data: htmlData, encoding: .ascii)
            guard let html, !html.isEmpty else { continue }
            return (type, htmlData, html)
        }
        return nil
    }

    static func htmlContainsTable(_ html: String) -> Bool {
        html.range(of: "<table", options: .caseInsensitive) != nil
    }

    static func htmlContainsImage(_ html: String) -> Bool {
        html.range(of: "<img", options: .caseInsensitive) != nil
    }

    static func htmlContainsInlineFormatting(_ html: String) -> Bool {
        let tags = ["<b>", "<b ", "<strong", "<i>", "<i ", "<em>", "<em ",
                    "<u>", "<u ", "<a ", "<h1", "<h2", "<h3", "<h4", "<h5", "<h6",
                    "<ul", "<ol", "<li", "<blockquote", "<mark", "<font", "style=",
                    "<code", "<pre", "<s>", "<s ", "<strike", "<del", "<sub", "<sup"]
        let lower = html.lowercased()
        return tags.contains { lower.contains($0) }
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

        s = s.replacingOccurrences(of: "<t[dh][^>]*>", with: "",
                                   options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "</t[dh][^>]*>", with: "\t",
                                   options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<br[^>]*>", with: "\n",
                                   options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)

        s = s.replacingOccurrences(of: "\t\n", with: "\n")
        let entities: [(String, String)] = [
            ("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&apos;", "'"), ("&#39;", "'"), ("&hellip;", "…"),
            ("&mdash;", "—"), ("&ndash;", "–"), ("&copy;", "©"), ("&reg;", "®"),
        ]
        for (e, r) in entities { s = s.replacingOccurrences(of: e, with: r) }
        s = s.replacingOccurrences(of: "&#(\\d+);", with: " ",
                                   options: .regularExpression)

        s = s.replacingOccurrences(of: " +", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func addUncapturedPlaceholder(reason: String, changeCount: Int) {
        guard uncapturedFallbackEnabled else { return }
        var item = ClipboardItem(content: .text(reason))
        item.isUncaptured = true
        item.uncapturedChangeCount = changeCount
        if let app = NSWorkspace.shared.frontmostApplication {
            item.sourceAppName  = app.localizedName
            item.sourceBundleID = app.bundleIdentifier
        }

        items.removeAll { $0.isUncaptured }
        items.insert(item, at: 0)
        selectedIndex = 0
        uncapturedPlaceholderChangeCount = changeCount
    }

    func purgeUncapturedPlaceholderIfSuperseded() {
        guard let stamped = uncapturedPlaceholderChangeCount else { return }
        guard stamped != NSPasteboard.general.changeCount else { return }
        uncapturedPlaceholderChangeCount = nil
        guard items.contains(where: { $0.isUncaptured }) else { return }
        let wasSelectedID = displayItems.indices.contains(selectedIndex)
            ? displayItems[selectedIndex].id : nil
        items.removeAll { $0.isUncaptured }
        if let wasSelectedID,
           let idx = displayItems.firstIndex(where: { $0.id == wasSelectedID }) {
            selectedIndex = idx
        } else {
            selectedIndex = 0
        }
    }

    func addItem(_ item: ClipboardItem) {
        captureAttemptGeneration &+= 1
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

        if item.collections.isEmpty, let activeCollection {
            item.collections = [activeCollection]
        }

        if case .text(let newText) = item.content {
            var mutableItem = item
            if let badge = computeDiffBadge(newText: newText, against: items) {
                mutableItem.diffBadge = badge
            }
            items.insert(mutableItem, at: 0)
        } else {
            items.insert(item, at: 0)
        }

        let trimmable = items.indices.filter { !items[$0].isPinned && !isRememberProtected(items[$0]) }
        if trimmable.count > maxItems, let oldest = trimmable.last {
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

        prewarmPreviewCaches(for: item)

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
                    let text = (req.results ?? [])
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
                    AIStructuringService.shared.autoAnalyzeIfNeeded(item: self.items[idx])
                }
            }
        }
    }

    func prewarmPreviewCaches(for item: ClipboardItem) {
        DispatchQueue.global(qos: .utility).async {
            Self.prewarmItem(item)
        }
    }

    private static func prewarmItem(_ item: ClipboardItem) {
        let content = item.content

        _ = TableCellExtractor.cells(for: item)

        _ = EmbeddedImageExtractor.firstImage(for: item)

        if case .image(let decodedImage, _, _) = content,
           ItemThumbnailCache.shared.cachedDataThumbnail(key: item.id.uuidString) == nil,
           let thumb = ItemThumbnailCache.resizedThumbnail(from: decodedImage, maxPixel: 360) {
            ItemThumbnailCache.shared.storeDataThumbnail(thumb, key: item.id.uuidString)
        }

        guard let plainText = content.plainText, !plainText.isEmpty else { return }

        let language: String? = {
            switch item.detectedType {
            case .code(let lang): return lang
            case .json:           return "json"
            case .latex:          return "latex"
            default:              return nil
            }
        }()
        if let language {
            let capped = String(plainText.prefix(CodeHighlighter.maxHighlightLength))
            _ = CodeHighlighter.shared.highlightSync(capped, languageDisplayName: language, dark: false)
            _ = CodeHighlighter.shared.highlightSync(capped, languageDisplayName: language, dark: true)
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

        if newLines.count >= 2 {
            return lineDiffBadge(newLines: newLines, against: existing)
        }

        return wordDiffBadge(newText: newText, against: existing)
    }

    /// Cached line split for one item's `textForEmbedding` — the same up to
    /// 10 antecedent items get compared against on every single new text
    /// capture, and without this their text was re-split/re-trimmed from
    /// scratch on the main thread every time even though it never changes
    /// between captures.
    private func cachedDiffLines(for item: ClipboardItem) -> [String] {
        if let cached = diffLineCache[item.id] { return cached }
        let lines = (item.textForEmbedding ?? "").components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        diffLineCache[item.id] = lines
        return lines
    }

    private func cachedDiffWords(for item: ClipboardItem) -> [String] {
        if let cached = diffWordCache[item.id] { return cached }
        let words = (item.textForEmbedding ?? "").split(whereSeparator: { $0.isWhitespace }).map(String.init)
        diffWordCache[item.id] = words
        return words
    }

    private func lineDiffBadge(newLines: [String], against existing: [ClipboardItem]) -> String? {
        let newSet = Set(newLines)

        for (i, item) in existing.prefix(10).enumerated() {
            guard let existText = item.textForEmbedding,
                  existText.count <= Self.maxDiffBadgeTextLength else { continue }
            let existLines = cachedDiffLines(for: item)
            guard existLines.count >= 2 else { continue }
            let existSet = Set(existLines)

            let shared = newSet.intersection(existSet).count
            let total  = newSet.union(existSet).count
            guard total > 0 else { continue }
            let similarity = Double(shared) / Double(total)
            guard similarity >= 0.4 && similarity < 1.0 else { continue }

            let addedLines   = newLines.filter   { !existSet.contains($0) }
            let removedLines = existLines.filter { !newSet.contains($0) }
            guard !addedLines.isEmpty || !removedLines.isEmpty else { continue }

            let rank = i + 2
            var parts: [String] = []
            if !addedLines.isEmpty   { parts.append("+\(addedLines.count)") }
            if !removedLines.isEmpty { parts.append("-\(removedLines.count)") }
            return parts.joined(separator: " ") + " from #\(rank)"
        }
        return nil
    }

    private func wordDiffBadge(newText: String, against existing: [ClipboardItem]) -> String? {
        let newWords = newText.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard newWords.count >= 2 else { return nil }
        let newSet = Set(newWords.map { $0.lowercased() })

        for (i, item) in existing.prefix(10).enumerated() {
            guard let existText = item.textForEmbedding,
                  existText.count <= Self.maxDiffBadgeTextLength else { continue }
            let existLines = cachedDiffLines(for: item)
            guard existLines.count < 2 else { continue }
            let existWords = cachedDiffWords(for: item)
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
            return parts.joined(separator: " ") + " from #\(rank)"
        }
        return nil
    }

    static func screenshotSaveDirectory() -> URL {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        task.arguments = ["read", "com.apple.screencapture", "location"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let path, !path.isEmpty {
                let expanded = (path as NSString).expandingTildeInPath
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue {
                    return URL(fileURLWithPath: expanded)
                }
            }
        } catch {

        }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
    }

    static func isScreenshotFilename(_ name: String) -> Bool {
        guard name.hasPrefix("Screenshot ") || name.hasPrefix("Screen Shot ") else { return false }
        let ext = (name as NSString).pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "tiff", "tif", "heic", "pdf"].contains(ext)
    }

    private static func screenCaptureDefault(_ key: String) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        task.arguments = ["read", "com.apple.screencapture", key]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        guard (try? task.run()) != nil else { return nil }
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func setScreenCaptureThumbnail(_ enabled: Bool) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        task.arguments = ["write", "com.apple.screencapture", "show-thumbnail",
                          "-bool", enabled ? "true" : "false"]
        try? task.run()
        task.waitUntilExit()
    }

    func enableScreenshotCaptureWithPermission() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            let priorThumbnail = Self.screenCaptureDefault("show-thumbnail") ?? "1"
            UserDefaults.standard.set(priorThumbnail, forKey: "clipen.priorScreenshotThumbnail")
            Self.setScreenCaptureThumbnail(false)

            let dir = Self.screenshotSaveDirectory()

            let readable = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) != nil

            DispatchQueue.main.async {
                if readable {
                    self.startScreenshotWatcher()
                } else {
                    CopyFeedbackPanel.shared.show(
                        message: String(localized: "Allow Clipen to access your screenshot folder in System Settings"))
                }
            }
        }
    }

    func disableScreenshotCapture() {
        stopScreenshotWatcher()
        let prior = UserDefaults.standard.string(forKey: "clipen.priorScreenshotThumbnail")

        let restoreOn = prior == nil || prior == "1" || prior?.lowercased() == "true"
        DispatchQueue.global(qos: .utility).async {
            Self.setScreenCaptureThumbnail(restoreOn)
        }
    }

    func startScreenshotWatcher() {
        stopScreenshotWatcher()

        let dir = Self.screenshotSaveDirectory()
        let existing = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []

        seenScreenshotPathsLock.withLock {
            seenScreenshotPaths = Set(existing.map { dir.appendingPathComponent($0).path })
        }

        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else {
            NSLog("[Clipen] screenshot watcher: couldn't open %@ (errno %d)", dir.path, errno)
            return
        }
        screenshotWatcherFD = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: .write, queue: DispatchQueue.global(qos: .utility))
        source.setEventHandler { [weak self] in
            self?.scanForNewScreenshots(in: dir)
        }
        source.setCancelHandler { [weak self] in
            if let fd = self?.screenshotWatcherFD, fd >= 0 { close(fd) }
            self?.screenshotWatcherFD = -1
        }
        source.resume()
        screenshotWatcherSource = source
    }

    func stopScreenshotWatcher() {
        screenshotWatcherSource?.cancel()
        screenshotWatcherSource = nil
        seenScreenshotPathsLock.withLock { seenScreenshotPaths.removeAll() }
    }

    private func scanForNewScreenshots(in dir: URL) {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {

            NSLog("[Clipen] screenshot watcher: %@ unreadable — likely missing Files-and-Folders permission", dir.path)
            return
        }
        for name in entries where Self.isScreenshotFilename(name) {
            let path = dir.appendingPathComponent(name).path

            let isNew = seenScreenshotPathsLock.withLock {
                seenScreenshotPaths.insert(path).inserted
            }
            guard isNew else { continue }

            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.35) { [weak self] in
                self?.pushScreenshotToClipboard(at: path)
            }
        }
    }

    private func pushScreenshotToClipboard(at path: String) {
        guard let sizeBefore = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int else { return }

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.15) {
            let sizeAfter = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int
            guard sizeAfter == sizeBefore, sizeAfter ?? 0 > 0 else { return }
            guard let image = NSImage(contentsOf: URL(fileURLWithPath: path)) else { return }
            DispatchQueue.main.async {
                let pb = NSPasteboard.general
                pb.clearContents()

                pb.writeObjects([image])
            }
        }
    }

}
