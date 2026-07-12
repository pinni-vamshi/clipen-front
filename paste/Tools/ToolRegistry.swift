import AppKit
import Foundation
import PDFKit

enum ToolRegistry {
    static func tools(for item: ClipboardItem) -> [ClipboardTool] {
        resolved(for: item).map { $0.tool }
    }

    // ── Single-entry resolution cache.
    //
    // `displays`, `tools`, and every run/lookup helper below funnel through
    // `resolved(for:)`. Opening the transform panel and then applying a tool
    // used to recompute the whole applicable-tools list repeatedly for the
    // SAME item — and each recompute ran every tool's `preview`, which
    // executes the real transform over the full text (a big JSON/CSV blob got
    // fully re-parsed per tool). Content is immutable, so resolution is a pure
    // function of the item id; cache the most-recent item's result and reuse
    // it. Lock-guarded because the run helpers can be reached off the main
    // thread (async apply / capture paths).
    private struct ResolvedTools {
        let itemID: UUID
        let entries: [(tool: ClipboardTool, preview: String?)]
    }
    private static var resolvedCache: ResolvedTools?
    private static let resolvedLock = NSLock()

    /// Applicable tools for `item`, each paired with the preview computed while
    /// deciding applicability, sorted by importance. Preview and importance
    /// score are computed EXACTLY ONCE per tool here — the old split
    /// `applicable` + `displays` ran every preview twice, and the sort
    /// recomputed each tool's score O(n log n) times.
    private static func resolved(for item: ClipboardItem) -> [(tool: ClipboardTool, preview: String?)] {
        resolvedLock.lock()
        if let cached = resolvedCache, cached.itemID == item.id {
            let entries = cached.entries
            resolvedLock.unlock()
            return entries
        }
        resolvedLock.unlock()

        let pool = toolPool(for: item)
        var scored: [(tool: ClipboardTool, preview: String?, score: Double, order: Int)] = []
        scored.reserveCapacity(pool.count)
        for (order, tool) in pool.enumerated() {
            if tool.id == "image.ocr", !AuthManager.shared.ocrEnabled { continue }
            if (tool.id == "pdf.extract-all-text" || tool.id == "pdf.first-page-text"),
               !AuthManager.shared.pdfTextExtract { continue }
            // A tool is applicable iff it produces a preview for this item.
            guard let preview = tool.preview(item) else { continue }
            scored.append((tool, preview, AuthManager.shared.toolImportanceScore(for: tool.id), order))
        }
        scored.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.order < rhs.order   // stable catalog order on score ties
        }
        let entries = scored.map { (tool: $0.tool, preview: $0.preview) }

        resolvedLock.lock()
        resolvedCache = ResolvedTools(itemID: item.id, entries: entries)
        resolvedLock.unlock()
        return entries
    }

    /// One primary pool per item so image/PDF/file tools sort among themselves
    /// (usage scores), not buried under unrelated text tools.
    private static func toolPool(for item: ClipboardItem) -> [ClipboardTool] {
        switch item.content {
        case .image:
            return ImageTools.all

        case .file(let url):
            if FileKindDetector.isVideoFile(url) || FileKindDetector.isAudioFile(url) {
                return MediaTools.all
            }
            if url.pathExtension.lowercased() == "pdf" {
                return PDFTools.all
            }
            return FileTools.all

        case .files(let urls):
            // A one-element files-list is functionally a single file — give it
            // the same specialized pool a `.file` capture of that URL would
            // get (media/PDF/image), not just the generic file tools.
            if urls.count == 1, let first = urls.first {
                if FileKindDetector.isVideoFile(first) || FileKindDetector.isAudioFile(first) {
                    return MediaTools.all
                }
                if first.pathExtension.lowercased() == "pdf" {
                    return PDFTools.all
                }
                if FileKindDetector.isImageFile(first) {
                    return ImageTools.all + FileTools.all
                }
            }
            return FileTools.all

        case .text, .richText, .rtfd, .html:
            return TextTools.all + FileTools.all

        case .svg:
            return TextTools.all  // SVG is text-editable; minify/copy tools apply

        case .blob:
            return []  // no transforms for opaque private data
        }
    }

    static func displays(for item: ClipboardItem) -> [TransformDisplay] {
        resolved(for: item).map { entry in
            // The preview is rendered two lines tall; a transform of a large
            // blob can produce a huge string, so cap what we hand to SwiftUI.
            let preview: String? = {
                guard let p = entry.preview, !p.isEmpty else { return nil }
                return p.count > 200 ? String(p.prefix(200)) : p
            }()
            return TransformDisplay(
                id: entry.tool.id,
                icon: entry.tool.icon,
                label: entry.tool.label,
                group: entry.tool.group,
                preview: preview
            )
        }
    }

    static func isAsync(item: ClipboardItem, index: Int) -> Bool {
        let t = tools(for: item)
        guard t.indices.contains(index) else { return false }
        return t[index].isAsync
    }

    static func runSync(item: ClipboardItem, index: Int) -> TransformOutput? {
        let tools = tools(for: item)
        guard tools.indices.contains(index), let runSync = tools[index].runSync else { return nil }
        return runSync(item)
    }

    static func run(item: ClipboardItem, index: Int) async -> TransformOutput? {
        let tools = tools(for: item)
        guard tools.indices.contains(index) else { return nil }
        return await tools[index].runAsync(item)
    }

    static func isAsync(item: ClipboardItem, toolID: String) -> Bool {
        guard let tool = tool(for: item, toolID: toolID) else { return false }
        return tool.isAsync
    }

    static func runSync(item: ClipboardItem, toolID: String) -> TransformOutput? {
        guard let tool = tool(for: item, toolID: toolID),
              let runSync = tool.runSync else { return nil }
        return runSync(item)
    }

    static func run(item: ClipboardItem, toolID: String) async -> TransformOutput? {
        guard let tool = tool(for: item, toolID: toolID) else { return nil }
        return await tool.runAsync(item)
    }

    static func toolID(item: ClipboardItem, index: Int) -> String? {
        let tools = tools(for: item)
        guard tools.indices.contains(index) else { return nil }
        return tools[index].id
    }

    private static func tool(for item: ClipboardItem, toolID: String) -> ClipboardTool? {
        tools(for: item).first(where: { $0.id == toolID })
    }
}
