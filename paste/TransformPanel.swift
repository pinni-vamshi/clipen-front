import AppKit
import SwiftUI
import Vision
@preconcurrency import PDFKit       // PDFKit pre-dates Swift Concurrency, silences Sendable warnings

// MARK: - Transform model

struct TextTransform: Identifiable {
    let id    = UUID()
    let icon:  String
    let label: String
    let group: String
    let apply: (String) -> String?

    /// Data-type-aware transforms. Each closure returns nil if the transform
    /// isn't meaningful for the input, so the panel only shows operations the
    /// user actually cares about for THIS clipboard item.
    ///
    /// Rules:
    ///   - JSON / URL transforms only show when content IS detected as that type
    ///   - Identifier-case transforms (snake/kebab/camel/Pascal) only show for
    ///     short single-line text that looks like a variable name
    ///   - Case transforms (UPPER/lower/Title) hide on URLs & JSON
    ///     (changing the case of a URL or JSON would break it)
    ///   - Trim whitespace shows only when there's actual leading/trailing space
    ///   - Base64 encode caps at 1KB; decode requires valid base64
    static let all: [TextTransform] = [
        // CASE — hide on URL / JSON / hex color (would corrupt them)
        .init(icon: "textformat",                  label: "Title Case", group: "CASE") {
            guard isPlainText($0) else { return nil }
            return $0.titleCased
        },
        .init(icon: "arrow.up.to.line.compact",    label: "UPPERCASE",  group: "CASE") {
            guard isPlainTextOrHexColor($0) else { return nil }
            let out = $0.uppercased()
            return out == $0 ? nil : out               // hide if no change
        },
        .init(icon: "arrow.down.to.line.compact",  label: "lowercase",  group: "CASE") {
            guard isPlainTextOrHexColor($0) else { return nil }
            let out = $0.lowercased()
            return out == $0 ? nil : out
        },

        // EDIT — only when there's actually whitespace to trim
        .init(icon: "scissors",                    label: "Trim whitespace", group: "EDIT") {
            let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed == $0 ? nil : trimmed
        },

        // FORMAT — JSON only (jsonPretty/Minify return nil for non-JSON)
        .init(icon: "curlybraces",                 label: "JSON Pretty", group: "FORMAT") { jsonPretty($0) },
        .init(icon: "curlybraces.square",          label: "JSON Minify", group: "FORMAT") { jsonMinify($0) },

        // ENCODE — URL transforms ONLY for URL content
        .init(icon: "link",                        label: "URL Encode", group: "ENCODE") {
            guard isURL($0) else { return nil }
            return $0.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
        },
        .init(icon: "link.badge.plus",             label: "URL Decode", group: "ENCODE") {
            // Show only when there ARE percent-escapes to decode
            guard $0.contains("%") else { return nil }
            let decoded = $0.removingPercentEncoding
            return decoded == $0 ? nil : decoded
        },
        .init(icon: "doc.badge.ellipsis",          label: "Base64 Encode", group: "ENCODE") {
            // Cap at 1KB — base64 of huge data isn't useful in a clipboard panel
            guard $0.count <= 1000, !$0.isEmpty else { return nil }
            return Data($0.utf8).base64EncodedString()
        },
        .init(icon: "doc.badge.minus",             label: "Base64 Decode", group: "ENCODE") {
            let s = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            guard s.count >= 4,
                  let d = Data(base64Encoded: s),
                  let r = String(data: d, encoding: .utf8),
                  !r.isEmpty else { return nil }
            return r
        },

        // DEV — only for identifier-like input (single line, no spaces in
        // the middle, mostly alphanumeric). Useless for prose / URLs / JSON.
        .init(icon: "square.2.layers.3d",          label: "snake_case", group: "DEV") {
            guard isIdentifierLike($0) else { return nil }
            let out = $0.toSnakeCase
            return out == $0 ? nil : out
        },
        .init(icon: "minus",                       label: "kebab-case", group: "DEV") {
            guard isIdentifierLike($0) else { return nil }
            let out = $0.toKebabCase
            return out == $0 ? nil : out
        },
        .init(icon: "c.circle",                    label: "camelCase",  group: "DEV") {
            guard isIdentifierLike($0) else { return nil }
            let out = $0.toCamelCase
            return out == $0 ? nil : out
        },
        .init(icon: "textformat.abc",              label: "PascalCase", group: "DEV") {
            guard isIdentifierLike($0) else { return nil }
            let out = $0.components(separatedBy: .init(charactersIn: " _-"))
                .filter { !$0.isEmpty }
                .map { $0.capitalized }
                .joined()
            return out == $0 ? nil : out
        },
    ]

    // MARK: - Detection helpers (shared by the transform predicates above)

    /// True when the input is a hex color like "#FFF" or "#FFAABB".
    private static func isHexColor(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("#"), t.count == 7 || t.count == 4 else { return false }
        return t.dropFirst().allSatisfy { $0.isHexDigit }
    }

    /// True when the input is a URL (http/https with a host).
    private static func isURL(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("http://") || t.hasPrefix("https://"),
              let url = URL(string: t), url.host != nil else { return false }
        return true
    }

    /// True when the input is valid JSON object / array.
    private static func isJSON(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("{") || t.hasPrefix("[") else { return false }
        return (try? JSONSerialization.jsonObject(with: Data(t.utf8))) != nil
    }

    /// True when the input is just plain text — not URL, JSON, or hex color.
    /// Used to gate case transforms (so they don't corrupt structured content).
    static func isPlainText(_ s: String) -> Bool {
        !isURL(s) && !isJSON(s) && !isHexColor(s)
    }

    /// Plain text OR hex color (UPPERCASE/lowercase makes sense for both).
    static func isPlainTextOrHexColor(_ s: String) -> Bool {
        !isURL(s) && !isJSON(s)
    }

    /// True when the input looks like a variable/identifier name —
    /// single line, short, mostly alphanumeric + spaces/underscores/dashes.
    /// Used to gate snake_case/kebab-case/etc., which are meaningless on prose.
    static func isIdentifierLike(_ s: String) -> Bool {
        guard !isURL(s), !isJSON(s), !isHexColor(s) else { return false }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count <= 80, !t.contains("\n") else { return false }
        // Must be made up of letters, digits, spaces, underscores, dashes
        let allowed = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: " _-"))
        return t.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static func jsonPretty(_ str: String) -> String? {
        guard let data = str.data(using: .utf8),
              let obj  = try? JSONSerialization.jsonObject(with: data),
              let out  = try? JSONSerialization.data(withJSONObject: obj, options: .prettyPrinted)
        else { return nil }
        return String(data: out, encoding: .utf8)
    }

    private static func jsonMinify(_ str: String) -> String? {
        guard let data = str.data(using: .utf8),
              let obj  = try? JSONSerialization.jsonObject(with: data),
              let out  = try? JSONSerialization.data(withJSONObject: obj, options: [])
        else { return nil }
        return String(data: out, encoding: .utf8)
    }
}

// MARK: - Image transforms (cycleable via ⌘X like text)

struct ImageTransform: Identifiable {
    let id     = UUID()
    let icon:  String
    let label: String
    let group: String
    /// Async because OCR / image processing can take a while.
    let apply: (NSImage) async -> String?

    static let all: [ImageTransform] = [
        .init(icon: "text.viewfinder", label: "Extract Text (OCR)", group: "VISION") { img in
            await OCRService.extractText(from: img)
        }
    ]
}

// MARK: - PDF transforms (cycleable via ⌘X like text)

struct PDFTransform: Identifiable {
    let id     = UUID()
    let icon:  String
    let label: String
    let group: String
    let apply: (PDFDocument) async -> String?

    static let all: [PDFTransform] = [
        .init(icon: "doc.text",  label: "Extract All Text", group: "TEXT") { pdf in
            await PDFService.extractAllText(from: pdf)
        },
        .init(icon: "doc",       label: "First Page Text",  group: "TEXT") { pdf in
            await PDFService.extractFirstPageText(from: pdf)
        },
        .init(icon: "number.circle", label: "Page Count",   group: "INFO") { pdf in
            "\(pdf.pageCount) pages"
        },
    ]
}

// MARK: - Reusable services (extracted from old per-view code)

enum OCRService {
    static func extractText(from img: NSImage) async -> String? {
        guard let cgImage = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                // Default Vision behavior runs every supported language
                // detector in parallel — slow and worse-quality. Hint the
                // user's preferred languages so Vision short-circuits to
                // them. On Apple Silicon this dispatches to the ANE and
                // halves OCR latency for typical English screenshots.
                let preferred = Locale.preferredLanguages.prefix(3).map { String($0) }
                request.recognitionLanguages = preferred.isEmpty ? ["en-US"] : preferred
                let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                try? handler.perform([request])
                let lines = (request.results ?? [])
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "\n")
                continuation.resume(returning: lines.isEmpty ? nil : lines)
            }
        }
    }
}

enum PDFService {
    /// PDFKit is not Swift-Concurrency-aware (its types aren't `Sendable`), so
    /// extract the actual strings *synchronously* on the calling thread first
    /// and only then jump into a background queue with plain `String` values.
    /// This avoids Swift 6's "capture of non-Sendable PDFDocument in @Sendable
    /// closure" warning entirely.

    static func extractAllText(from pdf: PDFDocument) async -> String? {
        // Pull strings out of PDFKit on the current actor — no Sendable issue.
        let pages: [String] = (0..<pdf.pageCount).compactMap { pdf.page(at: $0)?.string }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let combined = pages.joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: combined.isEmpty ? nil : combined)
            }
        }
    }

    static func extractFirstPageText(from pdf: PDFDocument) async -> String? {
        let raw = pdf.page(at: 0)?.string ?? ""
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: trimmed.isEmpty ? nil : trimmed)
            }
        }
    }
}

// MARK: - Unified display struct for the panel UI

/// Content-type-agnostic representation of a transform, used by the panel UI
/// to render the cycle list. The actual `apply` logic lives in `TransformResolver`
/// (sync for text, async for image/PDF) and dispatches on the underlying type.
struct TransformDisplay: Identifiable {
    let id:      UUID
    let icon:    String
    let label:   String
    let group:   String
    let preview: String?     // nil for non-text (would require running the transform)
}

// MARK: - Resolver: turn a ClipboardItem into a display list AND apply by index

enum TransformResolver {

    /// All transforms applicable to this item, in display order. Used for
    /// both the panel UI and for cycling (index → which transform to apply).
    ///
    /// Previously this ran `t.apply(s)` twice per transform — once to
    /// filter (`!= nil`) and once to populate `preview`. For text items
    /// with JSON/base64 transforms, `apply` is non-trivial (JSON parse,
    /// pretty-print, decode). Now we compute once and keep the result.
    static func displays(for item: ClipboardItem) -> [TransformDisplay] {
        switch item.content {

        case .text(let s):
            return textDisplays(input: s)

        case .richText(_, plain: let s):
            return textDisplays(input: s)

        case .image(_, _, let dataType) where dataType.rawValue.contains("pdf"):
            return PDFTransform.all.map { t in
                TransformDisplay(id: t.id, icon: t.icon, label: t.label,
                                 group: t.group, preview: nil)
            }

        case .image:
            return ImageTransform.all.map { t in
                TransformDisplay(id: t.id, icon: t.icon, label: t.label,
                                 group: t.group, preview: nil)
            }

        case .file(let url) where url.pathExtension.lowercased() == "pdf":
            return PDFTransform.all.map { t in
                TransformDisplay(id: t.id, icon: t.icon, label: t.label,
                                 group: t.group, preview: nil)
            }

        case .file(let url):
            return textDisplays(input: url.path)
        }
    }

    /// Shared helper for text-y content: apply once, keep results that
    /// returned non-nil. Halves the work compared to the old filter+map.
    private static func textDisplays(input s: String) -> [TransformDisplay] {
        TextTransform.all.compactMap { t in
            guard let preview = t.apply(s) else { return nil }
            return TransformDisplay(id: t.id, icon: t.icon, label: t.label,
                                    group: t.group, preview: preview)
        }
    }

    /// True when applying the transform at this index will run async work
    /// (so the panel can show a "Processing…" spinner before paste).
    static func isAsync(item: ClipboardItem, index: Int) -> Bool {
        switch item.content {
        case .text, .richText:                                 return false
        case .file(let url) where url.pathExtension.lowercased() == "pdf":
            return index < PDFTransform.all.count && PDFTransform.all[index].group == "TEXT"
        case .file:                                            return false
        case .image(_, _, let dataType) where dataType.rawValue.contains("pdf"):
            return index < PDFTransform.all.count && PDFTransform.all[index].group == "TEXT"
        case .image:                                           return true
        }
    }

    /// Run the transform at `index` for the given item and return the
    /// resulting paste-able string (async-ready for image/PDF).
    static func apply(item: ClipboardItem, index: Int) async -> String? {
        switch item.content {

        case .text(let s):
            let applicable = TextTransform.all.filter { $0.apply(s) != nil }
            guard applicable.indices.contains(index) else { return nil }
            return applicable[index].apply(s)

        case .richText(_, plain: let s):
            let applicable = TextTransform.all.filter { $0.apply(s) != nil }
            guard applicable.indices.contains(index) else { return nil }
            return applicable[index].apply(s)

        case .image(let img, let data, let dataType) where dataType.rawValue.contains("pdf"):
            guard let pdf = PDFDocument(data: data) ?? PDFDocument(data: img.tiffRepresentation ?? Data()),
                  PDFTransform.all.indices.contains(index) else { return nil }
            return await PDFTransform.all[index].apply(pdf)

        case .image(let img, _, _):
            guard ImageTransform.all.indices.contains(index) else { return nil }
            return await ImageTransform.all[index].apply(img)

        case .file(let url) where url.pathExtension.lowercased() == "pdf":
            guard let pdf = PDFDocument(url: url),
                  PDFTransform.all.indices.contains(index) else { return nil }
            return await PDFTransform.all[index].apply(pdf)

        case .file(let url):
            let applicable = TextTransform.all.filter { $0.apply(url.path) != nil }
            guard applicable.indices.contains(index) else { return nil }
            return applicable[index].apply(url.path)
        }
    }
}

// MARK: - NSPanel

class TransformPanel: NSPanel {
    private var hostingView: NSHostingView<AnyView>?

    init() {
        super.init(
            contentRect: .zero,
            styleMask:   [.nonactivatingPanel, .borderless],
            backing:     .buffered,
            defer:       false
        )
        level           = .floating
        isOpaque        = false
        backgroundColor = .clear
        hasShadow       = true
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    func show(for item: ClipboardItem,
              near popupFrame: NSRect,
              selectedTransformIndex: Int = 0,
              isProcessing: Bool = false) {

        // Source preview text shown at the top (nil for images / PDFs)
        let previewText: String? = {
            switch item.content {
            case .text(let s):               return s
            case .richText(_, plain: let s): return s
            case .file(let url):
                return url.pathExtension.lowercased() == "pdf" ? nil : url.path
            case .image:                     return nil
            }
        }()

        let displays = TransformResolver.displays(for: item)

        let view = AnyView(TransformView(
            previewText:            previewText,
            item:                   item,
            displays:               displays,
            selectedTransformIndex: selectedTransformIndex,
            isProcessing:           isProcessing,
            onDismiss:              { [weak self] in self?.hide() }
        ))

        if let hv = hostingView {
            hv.rootView = view
        } else {
            let hv = NSHostingView(rootView: view)
            contentView = hv
            hostingView = hv
        }

        let w: CGFloat = 290
        let h = min(hostingView?.fittingSize.height ?? 560, 620)
        let screen = NSScreen.main?.visibleFrame ?? .zero

        // Prefer right side of popup
        var x = popupFrame.maxX + 8
        if x + w > screen.maxX { x = popupFrame.minX - w - 8 }
        x = max(screen.minX + 8, x)
        let y = max(screen.minY + 8, min(popupFrame.minY, screen.maxY - h - 8))

        setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
        if !isVisible { orderFront(nil) }
    }

    func hide() { orderOut(nil) }

    func showUpgradePrompt(near popupFrame: NSRect) {
        let w: CGFloat = 300; let h: CGFloat = 160
        let x = popupFrame.maxX + 8
        let y = popupFrame.midY - h / 2
        let hv = NSHostingView(rootView: UpgradePromptView())
        contentView = hv
        setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
        if !isVisible { orderFront(nil) }
        // Auto-hide after 4 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.hide() }
    }
}

// MARK: - SwiftUI view

struct TransformView: View {
    /// Optional preview text to show at the top (for text-like items). nil
    /// means no preview block is rendered (images, PDFs).
    let previewText:            String?
    let item:                   ClipboardItem
    let displays:               [TransformDisplay]
    let selectedTransformIndex: Int
    let isProcessing:           Bool
    let onDismiss:              () -> Void

    private var stats: String {
        guard let text = previewText else {
            // For non-text items, show a content-aware summary
            switch item.content {
            case .image(let img, let data, _):
                let w = Int(img.size.width), h = Int(img.size.height)
                let kb = data.count / 1024
                return "\(w)×\(h) · \(kb) KB"
            case .file(let url):
                return url.path
            default:
                return ""
            }
        }
        let words = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.count
        let chars = text.count
        let lines = text.components(separatedBy: "\n").count
        return "\(words) words · \(chars) chars · \(lines) lines"
    }

    /// Distinct group keys in the order they appear in `displays`.
    private var groups: [String] {
        var seen = Set<String>()
        return displays.compactMap { d in
            seen.insert(d.group).inserted ? d.group : nil
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 6) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                Text("Transforms")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("⌘X cycle · release ⌘ apply")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)

            Divider()

            // Content type badge
            if let label = item.detectedType.badgeLabel {
                HStack(spacing: 6) {
                    Image(systemName: item.detectedType.sfIcon)
                        .font(.system(size: 10, weight: .semibold))
                    Text(label)
                        .font(.system(size: 10, weight: .semibold))
                    Spacer()
                    Text("detected")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
                .foregroundColor(item.detectedType.badgeColor)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(item.detectedType.badgeColor.opacity(0.12))

                Divider()
            }

            // Transform rows — only applicable ones, grouped; placeholder if none
            if displays.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "wand.and.stars.inverse")
                        .font(.system(size: 24, weight: .thin))
                        .foregroundColor(.secondary.opacity(0.4))
                    Text("No transforms available")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary.opacity(0.6))
                    Text("This content type can't be transformed")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary.opacity(0.4))
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 6) {
                            ForEach(groups, id: \.self) { group in
                                let groupDisplays = displays.filter { $0.group == group }
                                if !groupDisplays.isEmpty {
                                    VStack(spacing: 0) {
                                        HStack {
                                            Text(group)
                                                .font(.system(size: 9, weight: .semibold))
                                                .foregroundColor(.secondary)
                                                .tracking(1.5)
                                            Spacer()
                                        }
                                        .padding(.horizontal, 10)
                                        .padding(.top, 6)
                                        .padding(.bottom, 3)

                                        VStack(spacing: 0) {
                                            ForEach(Array(groupDisplays.enumerated()), id: \.element.id) { idx, display in
                                                let globalIdx = displays.firstIndex(where: { $0.id == display.id }) ?? 0
                                                let selected  = globalIdx == selectedTransformIndex
                                                TransformRow(
                                                    display:    display,
                                                    isSelected: selected,
                                                    isProcessing: selected && isProcessing
                                                )
                                                .id(display.id)
                                                if idx < groupDisplays.count - 1 {
                                                    Divider().padding(.leading, 36)
                                                }
                                            }
                                        }
                                        .background(.regularMaterial,
                                                    in: RoundedRectangle(cornerRadius: 9))
                                        .overlay(RoundedRectangle(cornerRadius: 9)
                                            .stroke(Color.primary.opacity(0.08), lineWidth: 1))
                                        .padding(.horizontal, 8)
                                    }
                                }
                            }
                            .padding(.bottom, 6)
                        }
                        .padding(.top, 4)
                    }
                    // Auto-scroll so the selected transform is always visible
                    .onChange(of: selectedTransformIndex) { _, newIdx in
                        guard displays.indices.contains(newIdx) else { return }
                        let id = displays[newIdx].id
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                    .onAppear {
                        guard displays.indices.contains(selectedTransformIndex) else { return }
                        let id = displays[selectedTransformIndex].id
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }

            Divider()

            // Stats
            Text(stats)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(Color.primary.opacity(0.1), lineWidth: 1))
        .shadow(color: .black.opacity(0.22), radius: 16, x: 0, y: 6)
    }
}

// MARK: - Transform row (content-type-agnostic — displays only, no apply logic)

struct TransformRow: View {
    let display:      TransformDisplay
    let isSelected:   Bool
    let isProcessing: Bool

    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: display.icon)
                .font(.system(size: 11))
                .foregroundColor(isSelected ? .white : .secondary)
                .frame(width: 16)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(display.label)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(isSelected ? .white : .primary)
                    Spacer()
                    if isProcessing {
                        ProgressView()
                            .scaleEffect(0.55)
                            .tint(isSelected ? .white : .accentColor)
                    } else if isSelected || isHovered {
                        Image(systemName: "return")
                            .font(.system(size: 9))
                            .foregroundColor(isSelected ? .white.opacity(0.7) : .accentColor.opacity(0.7))
                    }
                }
                if let preview = display.preview {
                    Text(preview.trimmingCharacters(in: .whitespacesAndNewlines))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(isSelected ? .white.opacity(0.75) : .secondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            isSelected
                ? Color.accentColor
                : (isHovered ? Color.accentColor.opacity(0.1) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovered)
        .animation(.easeInOut(duration: 0.12), value: isSelected)
    }
}

// MARK: - Shared content type badge

struct ContentTypeBadge: View {
    let type: ClipboardContentType

    var body: some View {
        if let label = type.badgeLabel {
            HStack(spacing: 3) {
                Image(systemName: type.sfIcon)
                    .font(.system(size: 7, weight: .bold))
                Text(label)
                    .font(.system(size: 8, weight: .bold))
            }
            .foregroundColor(type.badgeColor)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(type.badgeColor.opacity(0.15),
                        in: RoundedRectangle(cornerRadius: 4))
        }
    }
}

// MARK: - Upgrade prompt (shown to free users who try transforms)

struct UpgradePromptView: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.fill")
                .font(.system(size: 28))
                .foregroundColor(.orange)

            VStack(spacing: 6) {
                Text("Transforms are Pro")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.primary)
                Text("Upgrade to unlock text transforms,\nunlimited ring size, and more.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button("Upgrade to Pro →") {
                NSWorkspace.shared.open(URL(string: "https://clipen.app/upgrade")!)
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background(Color.orange, in: RoundedRectangle(cornerRadius: 7))
            .buttonStyle(.plain)
        }
        .padding(20)
        .frame(width: 300, height: 160)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(Color.orange.opacity(0.3), lineWidth: 1))
    }
}
