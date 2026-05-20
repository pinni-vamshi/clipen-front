import AppKit

enum TransformOutput {
    case text(String)
    case item(ClipboardItem, message: String)
    case files([URL], message: String)
    case revealFiles([URL], message: String)
    case status(String)
}

struct TransformDisplay: Identifiable {
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
