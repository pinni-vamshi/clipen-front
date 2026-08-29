import AppKit
import SwiftUI
import Vision
import NaturalLanguage
import ImageIO
@preconcurrency import PDFKit

extension ClipboardManager {

    /// 100ms while recently active, backing off to 500ms after a minute of
    /// nothing happening. macOS gives third-party apps no push notification
    /// for "the pasteboard changed" — this timer polling changeCount is the
    /// only mechanism available, at any interval — so the real tradeoff is
    /// just latency vs. always-on CPU/battery cost. A fixed 100ms forever
    /// pays that cost during the long idle stretches (laptop open, working
    /// in another app, watching something) that make up most of a real
    /// day, for detection speed nobody is around to benefit from. Snaps
    /// back to 100ms the instant real activity resumes — see
    /// lastPollActivityAt, bumped both by an actual detected change here
    /// and by the popup opening (openPopupNow), since opening it is itself
    /// a strong signal a copy or paste is imminent.
    ///
    /// A self-rescheduling one-shot chain, not a fixed repeating Timer,
    /// because Timer's own interval can't be changed after creation.
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
        // Ahead of every other guard on purpose. The placeholder has to go
        // the moment the pasteboard moves on, and two of the ways that
        // happens skip the rest of this function entirely: Clipen's own
        // paste (which sets isSimulatingPaste to suppress re-capture) and
        // any window where capture is paused.
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

        // Universal backstop, independent of which content-type branch this
        // change ends up taking: if nothing reaches addItem — real insert OR
        // a legitimate duplicate-of-the-top-entry skip, either counts —
        // within a generous window, show the "can't copy" badge. This is on
        // top of the specific feedback calls already in each branch below
        // (those fire immediately; this only ever matters when every one of
        // them missed a case), not a replacement for them.
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

        // HTML is read once, up front, so both the RTFD-vs-HTML priority
        // decision below and the actual HTML capture path use the exact
        // same decoded string — never two independent reads that could
        // disagree.
        let htmlCandidate = Self.readHTML(from: pb)
        let htmlIsSubstantial = htmlCandidate.map {
            Self.htmlContainsTable($0.html) || Self.htmlContainsImage($0.html)
                || Self.htmlContainsInlineFormatting($0.html)
        } ?? false

        // Prefer substantial HTML (a table, an image, or real inline
        // formatting) over RTFD when both are on the pasteboard at once —
        // RTF/RTFD can't express CSS backgrounds, button-styled links, or
        // real table styling, so an app that offers both on the same copy
        // (Mail.app copying an email, a browser copying a page) was always
        // silently getting the weaker RTFD capture, purely because RTFD
        // used to be checked first regardless of which one actually
        // preserved more of the original. Trivial/plain HTML (no table,
        // image, or formatting worth keeping) still defers to RTFD when
        // RTFD is available — RTFD is the richer signal for plain rich
        // text documents that never had real HTML behind them.
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

        // Same whitespace-only guard as basicItem's identical check below —
        // see its comment for why this can't just be !str.isEmpty.
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
            // Some apps (Mac Catalyst ones especially — measured directly
            // against WhatsApp Desktop: ~200ms from the first pasteboard
            // write to public.png actually appearing) write the pasteboard
            // in stages under one changeCount generation. A poll landing in
            // that window sees a genuinely incomplete write and correctly,
            // at that instant, finds nothing decodable — but the full write
            // finishes moments later. One retry after a delay comfortably
            // past the measured worst case catches that instead of giving
            // up off a single poll. Guarded by changeCount so a genuinely
            // different copy landing in the meantime isn't mistaken for
            // this one finishing.
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
                    DispatchQueue.main.async {
                        CopyFeedbackPanel.shared.show()
                        AuthManager.shared.registerActionUsage(actionID: "fail.capture")
                    }
                }
            }
        }
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
            // TIFF is never read back out of the sidecar by anything — the
            // one place TIFF matters (image paste) writes it explicitly at
            // the primary content step (see shouldAttachTiffFallback in
            // ClipboardManager+Paste.swift), not from here. Left in, it's
            // dead weight that rides along on every single paste: apps that
            // offer TIFF (Mail, most raster-heavy senders) often make it
            // the single biggest item on the pasteboard — one observed copy
            // carried a 22MB TIFF next to a 2MB PNG of the same image —
            // and `applySidecar` writes every surviving sidecar entry
            // synchronously on every paste regardless of content type.
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
            // Excludes HTML's own types only — the RTF/RTFD siblings MUST
            // survive here. When a source offers both at once (Mail.app,
            // every newsletter), the HTML holds the CSS but its <img> tags
            // are just references the pasteboard doesn't carry, while the
            // RTFD holds the actual image bytes as attachments. Dropping
            // RTFD therefore throws every image away: the capture still
            // previews perfectly, because the preview is a WKWebView that
            // fetches those URLs off the network, but a target app that
            // doesn't fetch remote images (Notes, Pages, most editors)
            // pastes an empty box for every one of them. Keeping both lets
            // the target pick — CSS where HTML is preferred, images where
            // RTFD is, which is exactly what pasting from Mail directly
            // does.
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
        // Trimmed before the emptiness check, not raw — a source that
        // writes a single space or newline as its plain-text fallback (Google
        // Slides does this on a shape/group selection: the whole pasteboard
        // is genuinely empty content dressed up as one whitespace byte)
        // used to pass `!str.isEmpty` and get captured as a real history
        // entry with nothing in it. Untrimmed `str` is still what gets
        // stored below — only the gate changes, so real content that
        // happens to start/end with whitespace is untouched.
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

        // Mac Catalyst apps (WhatsApp Desktop among them) sometimes write a
        // UIImage frozen with NSKeyedArchiver instead of real image bytes —
        // "com.apple.uikit.image" is a binary-plist encoding of a UIKit
        // object graph, not a file in any format a decoder could open.
        // Confirmed live against a real WhatsApp copy: the archive's
        // "UIImageData" key references a $objects entry that IS the raw
        // image bytes (a PNG in the observed case) — reading that plist
        // entry directly recovers the real picture without needing UIKit
        // itself. This also tends to land first in a Catalyst app's staged
        // pasteboard write, before public.png/heic/jpeg appear moments
        // later, so this check running early can succeed sooner than
        // waiting for those.
        if let extracted = Self.imageFromUIKitArchive(pb) {
            return ClipboardItem(content: extracted)
        }

        // WebP isn't decodable via plain NSImage(data:) — AppKit has no native
        // decoder for it — so it needs its own check ahead of the loop below,
        // using the same WebPDecoder the rest of the app already relies on
        // (see ImageService.decodeWebP). Without this, a WebP clipboard write
        // (WhatsApp Desktop copies images as WebP) falls through every image
        // check below, then even the generic NSImage(pasteboard:) fallback
        // fails for the same reason, and the whole capture degrades to
        // .blob — shown in the UI as "Private" with a lock icon, which is
        // not a privacy protection here, just a failed image decode.
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

        // Last resort before giving up on this being an image at all: ask
        // ImageIO directly, format-agnostic, instead of only ever checking
        // the specific UTIs enumerated above. This is what actually catches
        // "some format we didn't think to list" (ICO, ICNS, RAW variants,
        // whatever a given app happens to write) rather than requiring a
        // new hardcoded case every time one more app surprises us the way
        // WebP did — decoding it once here beats enumerating formats forever.
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

        // Deliberately not falling back to .blob anymore: an entry showing
        // up in history labeled "Private" with nothing behind it was never
        // useful, just clutter. The caller shows brief cursor feedback
        // instead of capturing anything here. .blob stays a real
        // ClipboardContent case for paste-back on any items a user already
        // has saved from before this changed.
        return nil
    }

    /// Recovers a real image from a Mac Catalyst app's frozen UIImage
    /// object on the pasteboard, without linking UIKit. NSKeyedArchiver
    /// plists reference shared objects via `CFKeyedArchiverUID`, a private
    /// class not exposed through public API or KVC — its numeric index is
    /// only available via its debug description ("...{value = N}"), which
    /// is why this parses that string instead of using the UID object
    /// directly. Verified against real captured WhatsApp Desktop data: the
    /// dictionary holding "UIImageData" references an $objects entry that
    /// is the actual image bytes (a PNG in every case observed), not
    /// further archived state — reading it directly recovers the picture.
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
        // Every case observed so far embeds a PNG, but tag by the actual
        // magic bytes rather than assume — this only affects which UTI the
        // recovered image is declared as, not whether it decoded.
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

    /// The one place that decodes `public.html` off a pasteboard — shared by
    /// the substantial-HTML-vs-RTFD priority check and the actual HTML
    /// capture path below, so there's exactly one multi-encoding fallback
    /// list to maintain, not two copies that could drift apart.
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

    /// Bold, italic, links, colors, headings, lists — anything the plain-
    /// text comparison right above this can't see, because none of it
    /// changes the plain-text characters, only how they look. Without this,
    /// copying e.g. a paragraph with a couple of bold words downgrades
    /// silently to plain .text (same characters either way, so the
    /// pasteboardPlain == plain check passes) and every bit of that
    /// formatting is gone on paste — indistinguishable from the user having
    /// turned "paste plain text by default" on, which they never touched.
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

    /// Record a copy macOS never let us read as a visible, flagged ring
    /// entry instead of dropping it silently. The real bytes are not ours
    /// to store (that is the whole reason this path exists), so the entry
    /// carries only a label plus the pasteboard change count that was
    /// current when it failed — enough for the paste path to prove, later,
    /// whether that content is still the live pasteboard content.
    ///
    /// Deliberately does NOT route through addItem: that bumps
    /// captureAttemptGeneration, which is exactly the signal the 0.7s
    /// backstop in pollClipboard uses to decide a capture failed. Feeding
    /// this insert through it would make a failure look like a success.
    func addUncapturedPlaceholder(reason: String, changeCount: Int) {
        guard uncapturedFallbackEnabled else { return }
        var item = ClipboardItem(content: .text(reason))
        item.isUncaptured = true
        item.uncapturedChangeCount = changeCount
        if let app = NSWorkspace.shared.frontmostApplication {
            item.sourceAppName  = app.localizedName
            item.sourceBundleID = app.bundleIdentifier
        }
        // Only ever one live placeholder: the system pasteboard holds a
        // single slot, so at most one uncaptured copy can still be
        // pastable at any moment. Older ones are already unreachable.
        items.removeAll { $0.isUncaptured }
        items.insert(item, at: 0)
        selectedIndex = 0
        uncapturedPlaceholderChangeCount = changeCount
    }

    /// Drop the uncaptured placeholder as soon as the pasteboard moves past
    /// the copy it stands for.
    ///
    /// The entry owns no content — it is only a pointer at whatever is live
    /// on the system pasteboard, and for the cases that produce it (promised
    /// data: an undownloaded Mail attachment, some WhatsApp images) there are
    /// no bytes for anyone to keep. macOS drops the source app's promise the
    /// instant another copy takes ownership, so at that moment the content is
    /// unreachable by every app on the machine, Clipen included. An entry
    /// that can never paste again is worse than no entry, so it is removed
    /// rather than left to fail later.
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

        // Items in a remember-forever collection are excluded here, same
        // as pinned items — never deleted by ring trimming. Unlike
        // pinning, they still eventually stop appearing in "All" once
        // they fall outside the ring window (handled in displayItems),
        // but the item itself and its files are never removed.
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

        // Warm the row thumbnail here, off-main, so materialising an image
        // row mid-scroll is a cache hit instead of a synchronous decode.
        // Resized from the image capture already decoded (ringThumbnail, at
        // capture time) rather than re-run through ImageIO on the raw
        // compressed bytes a second time — that redecode is where the cost
        // actually was, especially for alpha-heavy screenshots. See
        // resizedThumbnail's doc comment for the measurement.
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

    private func lineDiffBadge(newLines: [String], against existing: [ClipboardItem]) -> String? {
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
            let existLines = existText.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard existLines.count < 2 else { continue }
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
            return parts.joined(separator: " ") + " from #\(rank)"
        }
        return nil
    }

    // MARK: - Automatic screenshot capture

    /// Where macOS itself saves screenshots — user-configurable via the
    /// screenshot toolbar (Cmd+Shift+5, Options, Save to), stored under the
    /// key "location" in the com.apple.screencapture defaults domain.
    /// Reading that, rather than hardcoding ~/Desktop, is what makes this
    /// work for anyone who has changed the save folder; ~/Desktop is only
    /// the fallback macOS itself uses when that key was never set.
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
            // Falls through to the Desktop default below.
        }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
    }

    /// Matches both the current macOS naming ("Screenshot" prefix) and the
    /// pre-Big Sur one ("Screen Shot" prefix) some users still have their
    /// Mac set to via language/region settings, across every format the
    /// screenshot tool can be configured to save as — PNG by default, but
    /// JPEG, TIFF, PDF and HEIC are all valid via the screencapture "type"
    /// default.
    static func isScreenshotFilename(_ name: String) -> Bool {
        guard name.hasPrefix("Screenshot ") || name.hasPrefix("Screen Shot ") else { return false }
        let ext = (name as NSString).pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "tiff", "tif", "heic", "pdf"].contains(ext)
    }

    /// Read one key out of the com.apple.screencapture domain.
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

    /// Everything that must happen at the moment the user turns the toggle
    /// ON — deliberately not at launch, so Clipen never stacks this prompt
    /// on top of its Accessibility one.
    ///
    /// Two separate obstacles, both of which silently produce "nothing
    /// happens" if left alone:
    ///
    /// 1. macOS gates the screenshot folder behind Files-and-Folders TCC
    ///    even for non-sandboxed apps. The prompt only appears on a real
    ///    read attempt, so one is made here, on a background thread,
    ///    explicitly at opt-in time.
    /// 2. The floating screenshot thumbnail. While it is showing, macOS has
    ///    NOT yet written the file — and if the user drags that thumbnail
    ///    straight into another app, the file is never written at all.
    ///    Nothing lands on disk, so no folder watcher of any kind can see
    ///    it. Turning the thumbnail off makes every screenshot hit disk
    ///    immediately, which is what makes this work every time rather than
    ///    only when the user waits for the preview to fade. The previous
    ///    value is remembered so switching the toggle back off restores
    ///    whatever the user had before Clipen touched it.
    func enableScreenshotCaptureWithPermission() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            let priorThumbnail = Self.screenCaptureDefault("show-thumbnail") ?? "1"
            UserDefaults.standard.set(priorThumbnail, forKey: "clipen.priorScreenshotThumbnail")
            Self.setScreenCaptureThumbnail(false)

            let dir = Self.screenshotSaveDirectory()
            // The read itself is what raises the TCC prompt.
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

    /// Undo only what we actually changed — restores the thumbnail to
    /// whatever it was before, rather than blindly turning it back on.
    func disableScreenshotCapture() {
        stopScreenshotWatcher()
        let prior = UserDefaults.standard.string(forKey: "clipen.priorScreenshotThumbnail")
        // Absent or "1"/"true" both mean it was on; anything else means the
        // user already had it off and we leave it that way.
        let restoreOn = prior == nil || prior == "1" || prior?.lowercased() == "true"
        DispatchQueue.global(qos: .utility).async {
            Self.setScreenCaptureThumbnail(restoreOn)
        }
    }

    func startScreenshotWatcher() {
        stopScreenshotWatcher()

        let dir = Self.screenshotSaveDirectory()
        let existing = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        // Seed with whatever's already there so only screenshots taken
        // AFTER the watcher starts get copied — not every old one already
        // sitting in the folder.
        seenScreenshotPaths = Set(existing.map { dir.appendingPathComponent($0).path })

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
        seenScreenshotPaths.removeAll()
    }

    private func scanForNewScreenshots(in dir: URL) {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            // Almost always TCC: macOS protects Desktop/Documents/Downloads
            // for non-sandboxed apps, and a denied read fails silently rather
            // than throwing anything actionable. Logged so this is
            // diagnosable rather than looking like the feature "just does
            // nothing".
            NSLog("[Clipen] screenshot watcher: %@ unreadable — likely missing Files-and-Folders permission", dir.path)
            return
        }
        for name in entries where Self.isScreenshotFilename(name) {
            let path = dir.appendingPathComponent(name).path
            guard !seenScreenshotPaths.contains(path) else { continue }
            seenScreenshotPaths.insert(path)
            // A short settle delay: the directory write event can fire
            // while the screenshot tool is still flushing the file to disk,
            // especially for a large or multi-display capture — reading it
            // too early risks a truncated image. Re-checking the file size
            // is stable across a short wait is cheap insurance against that.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.35) { [weak self] in
                self?.pushScreenshotToClipboard(at: path)
            }
        }
    }

    private func pushScreenshotToClipboard(at path: String) {
        let url = URL(fileURLWithPath: path)
        guard let sizeBefore = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int else { return }
        Thread.sleep(forTimeInterval: 0.15)
        let sizeAfter = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int
        guard sizeAfter == sizeBefore, sizeAfter ?? 0 > 0 else { return } // still being written — the next directory event will retry it
        guard let image = NSImage(contentsOf: url) else { return }
        DispatchQueue.main.async {
            let pb = NSPasteboard.general
            pb.clearContents()
            // Deliberately NOT markPasteboardWriteAsOwn() — that flag exists
            // to make the NEXT poll ignore a write Clipen made on the
            // user's behalf when pasting FROM history, so that re-pasting an
            // item never re-captures it as "new". A screenshot is exactly
            // the opposite case: it genuinely IS new content the user just
            // created, and skipping capture here would defeat the entire
            // point of this feature.
            pb.writeObjects([image])
        }
    }

}
