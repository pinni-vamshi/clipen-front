import AppKit

enum TransformOutput {
    case text(String)
    case item(ClipboardItem, message: String)
    case files([URL], message: String)
    case revealFiles([URL], message: String)
    case status(String)
}

struct TransformDisplay: Identifiable, Equatable {
    let id:      String
    let icon:    String
    let label:   String
    let group:   String
    let preview: String?
}

struct ClipboardTool: Identifiable {
    let id:      String
    let icon:    String
    let label:   String
    let group:   String
    let preview: (ClipboardItem) -> String?
    let runSync: ((ClipboardItem) -> TransformOutput?)?
    let runAsync: (ClipboardItem) async -> TransformOutput?

    var isAsync: Bool { runSync == nil }

    init(
        id: String,
        icon: String,
        label: String,
        group: String,
        preview: @escaping (ClipboardItem) -> String? = { _ in nil },
        runSync: ((ClipboardItem) -> TransformOutput?)? = nil,
        runAsync: @escaping (ClipboardItem) async -> TransformOutput?
    ) {
        self.id = id
        self.icon = icon
        self.label = label
        self.group = group
        self.preview = preview
        self.runSync = runSync
        self.runAsync = runAsync
    }
}

/// Transforms available on a ⌘+G group: split it back apart, or paste only a
/// single data type out of it. A group's normal ⌘-release paste already drops
/// every member in order; these give finer control.
enum GroupTools {
    static var all: [ClipboardTool] { [ungroup, pasteText, pasteFiles, pasteImages] }

    private static func children(_ item: ClipboardItem) -> [ClipboardItem]? {
        if case .group(let items) = item.content { return items }
        return nil
    }

    static let ungroup = ClipboardTool(
        id: "group.ungroup", icon: "square.stack.3d.up.slash.fill",
        label: "Ungroup", group: "Group",
        preview: { children($0) != nil ? "Split into individual items" : nil },
        runSync: { item in
            // Ring operation, not a paste — perform it on the main actor and
            // report status so the transform panel just closes cleanly.
            DispatchQueue.main.async { ClipboardManager.shared.ungroup(item) }
            return .status("Ungrouped")
        },
        runAsync: { _ in nil }
    )

    static let pasteText = ClipboardTool(
        id: "group.paste-text", icon: "doc.text",
        label: "Paste Text Only", group: "Group",
        preview: { item in
            guard let kids = children(item) else { return nil }
            let texts = kids.compactMap { $0.content.plainText }.filter { !$0.isEmpty }
            return texts.isEmpty ? nil : "\(texts.count) text items"
        },
        runSync: { item in
            guard let kids = children(item) else { return nil }
            let joined = kids.compactMap { $0.content.plainText }.filter { !$0.isEmpty }.joined(separator: "\n")
            return joined.isEmpty ? nil : .text(joined)
        },
        runAsync: { _ in nil }
    )

    static let pasteFiles = ClipboardTool(
        id: "group.paste-files", icon: "doc.on.doc",
        label: "Paste Files Only", group: "Group",
        preview: { item in
            guard let kids = children(item) else { return nil }
            let urls = ClipboardItem.flattenedFileURLs(kids)
            return urls.isEmpty ? nil : "\(urls.count) files"
        },
        runSync: { item in
            guard let kids = children(item) else { return nil }
            let urls = ClipboardItem.flattenedFileURLs(kids)
                .filter { FileManager.default.fileExists(atPath: $0.path) }
            return urls.isEmpty ? nil : .files(urls, message: "Pasted \(urls.count) files")
        },
        runAsync: { _ in nil }
    )

    static let pasteImages = ClipboardTool(
        id: "group.paste-images", icon: "photo",
        label: "Paste First Image", group: "Group",
        preview: { item in
            guard let kids = children(item) else { return nil }
            let imgs = kids.filter { if case .image = $0.content { return true }; return false }
            return imgs.isEmpty ? nil : "\(imgs.count) images"
        },
        runSync: { item in
            guard let kids = children(item) else { return nil }
            guard let firstImage = kids.first(where: { if case .image = $0.content { return true }; return false })
            else { return nil }
            return .item(firstImage, message: "Pasted image")
        },
        runAsync: { _ in nil }
    )
}

/// Transforms that file a clip into another collection. Built fresh from the
/// user's collection list on every lookup, so renaming or adding a collection
/// is reflected immediately. Two flavours per destination:
///   • Move  — leave the collection it's showing under, join the destination.
///   • Also in — join the destination while staying where it already is
///     (collections are multi-membership, so a clip can live in several).
enum CollectionTools {
    static func all(for item: ClipboardItem) -> [ClipboardTool] {
        let manager = ClipboardManager.shared
        let active = manager.activeCollection
        var tools: [ClipboardTool] = []

        for name in manager.collections {
            // No point offering a destination the clip already sits in.
            guard !item.collections.contains(name) else { continue }

            if let active, active != name {
                tools.append(ClipboardTool(
                    id: "collection.move.\(name)", icon: "arrow.right.circle",
                    label: String(localized: "Move to \(name)"), group: String(localized: "Collections"),
                    preview: { _ in String(localized: "Leave \(active), file under \(name)") },
                    runSync: { item in
                        DispatchQueue.main.async {
                            ClipboardManager.shared.moveItem(item.id, toCollection: name)
                        }
                        return .status(String(localized: "Moved to \(name)"))
                    },
                    runAsync: { _ in nil }
                ))
            }

            tools.append(ClipboardTool(
                id: "collection.share.\(name)", icon: "plus.circle",
                label: String(localized: "Also in \(name)"), group: String(localized: "Collections"),
                preview: { _ in String(localized: "Keep here and file under \(name) too") },
                runSync: { item in
                    DispatchQueue.main.async {
                        ClipboardManager.shared.shareItem(item.id, toCollection: name)
                    }
                    return .status(String(localized: "Added to \(name)"))
                },
                runAsync: { _ in nil }
            ))
        }
        return tools
    }
}
