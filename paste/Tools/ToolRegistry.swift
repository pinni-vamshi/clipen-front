import AppKit
import Foundation

enum ToolRegistry {
    static func tools(for item: ClipboardItem) -> [ClipboardTool] {
        resolved(for: item).map { $0.tool }
    }

    private struct ResolvedTools {
        let itemID: UUID
        let entries: [(tool: ClipboardTool, preview: String?)]
    }
    private static var resolvedCache: ResolvedTools?
    private static let resolvedLock = NSLock()

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
            guard let preview = tool.preview(item) else { continue }
            scored.append((tool, preview, AuthManager.shared.toolImportanceScore(for: tool.id), order))
        }
        scored.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.order < rhs.order
        }
        let entries = scored.map { (tool: $0.tool, preview: $0.preview) }

        resolvedLock.lock()
        resolvedCache = ResolvedTools(itemID: item.id, entries: entries)
        resolvedLock.unlock()
        return entries
    }

    /// Every registered tool, from every domain file, considered for every
    /// item regardless of its content type. There is no outer type-based
    /// routing here on purpose: each tool's own `preview` closure is already
    /// the sole authority on whether it applies to a given item (see
    /// `ImageService.imageInput(for:)`, `PDFTools.pdfInput(for:)`,
    /// `FileTools.fileURLs(for:)`, `TextTools.input(for:)` — every one of
    /// them independently inspects the item and returns nil when it doesn't
    /// apply). A tool is just a tool; it isn't filed under "the image tools"
    /// or "the text tools" as a precondition for showing up somewhere, and
    /// ranking (`AuthManager.toolImportanceScore(for: tool.id)`) already
    /// operates purely per-tool-id, with no notion of which array declared it.
    private static let allTools: [ClipboardTool] =
        TextTools.all + ImageTools.all + FileTools.all + PDFTools.all + MediaTools.all

    private static func toolPool(for item: ClipboardItem) -> [ClipboardTool] {
        if case .blob = item.content { return [] }
        return allTools
    }

    static func displays(for item: ClipboardItem) -> [TransformDisplay] {
        resolved(for: item).map { entry in
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
