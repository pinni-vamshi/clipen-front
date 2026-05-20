import SwiftUI

/// Top-level category bucket each clipboard item falls into. Drives the
/// horizontal chip strip in the popover so the user can narrow the ring down.
enum ClipboardCategory: String, CaseIterable, Hashable {
    case code, color, contact, file, html, image, json, latex, markdown, richText, table, text, url

    var label: String {
        switch self {
        case .code:     return "Code"
        case .color:    return "Color"
        case .contact:  return "Contact"
        case .file:     return "Files"
        case .html:     return "HTML"
        case .image:    return "Images"
        case .json:     return "JSON"
        case .latex:    return "LaTeX"
        case .markdown: return "Markdown"
        case .richText: return "Rich text"
        case .table:    return "Tables"
        case .text:     return "Text"
        case .url:      return "URLs"
        }
    }

    var icon: String {
        switch self {
        case .code:     return "chevron.left.forwardslash.chevron.right"
        case .color:    return "paintpalette"
        case .contact:  return "person.text.rectangle"
        case .file:     return "doc"
        case .html:     return "globe"
        case .image:    return "photo"
        case .json:     return "curlybraces"
        case .latex:    return "function"
        case .markdown: return "doc.plaintext"
        case .richText: return "doc.richtext"
        case .table:    return "tablecells"
        case .text:     return "doc.text"
        case .url:      return "link"
        }
    }
}
