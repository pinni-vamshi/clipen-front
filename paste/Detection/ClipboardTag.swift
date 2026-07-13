import SwiftUI

enum ClipboardTag: String, Hashable, CaseIterable {
    case image
    case gif
    case pdf
    case svg
    case blob
    case file
    case files
    case video
    case audio
    case model3D
    case document
    case archive
    case design
    case font
    case installer
    case url
    case json
    case markdown
    case latex
    case table
    case email
    case phone
    case address
    case code
    case color
    case text
    case html
    case richText

    var folderName: String { rawValue }

    var priority: Int {
        switch self {
        case .image:     return 10
        case .gif:       return 11
        case .pdf:       return 12
        case .svg:       return 13
        case .blob:      return 15
        case .files:     return 14
        case .file:      return 16
        case .video:     return 18
        case .audio:     return 20
        case .model3D:   return 22
        case .document:  return 23
        case .design:    return 24
        case .archive:   return 25
        case .font:      return 26
        case .installer: return 27
        case .url:       return 30
        case .json:      return 32
        case .table:     return 34
        case .email, .phone, .address: return 36
        case .code:      return 38
        case .latex:     return 40
        case .markdown:  return 42
        case .color:     return 44
        case .text:      return 50
        case .html:      return 70
        case .richText:  return 72
        }
    }

    var label: String {
        switch self {
        case .image:    return "Image"
        case .gif:      return "GIF"
        case .pdf:      return "PDF"
        case .svg:      return "SVG"
        case .blob:     return "Private"
        case .file:     return "File"
        case .files:    return "Files"
        case .video:    return "Video"
        case .audio:    return "Audio"
        case .model3D:  return "3D"
        case .document: return "Doc"
        case .archive:  return "Archive"
        case .design:   return "Design"
        case .font:     return "Font"
        case .installer: return "Installer"
        case .url:      return "URL"
        case .json:     return "JSON"
        case .markdown: return "MD"
        case .latex:    return "LaTeX"
        case .table:    return "Table"
        case .email:    return "Email"
        case .phone:    return "Phone"
        case .address:  return "Address"
        case .code:     return "Code"
        case .color:    return "Color"
        case .text:     return "Text"
        case .html:     return "HTML"
        case .richText: return "Rich"
        }
    }

    var icon: String {
        switch self {
        case .image:    return "photo"
        case .gif:      return "photo.stack"
        case .pdf:      return "doc.richtext"
        case .svg:      return "square.on.circle"
        case .blob:     return "lock.doc"
        case .file:     return "doc"
        case .files:    return "doc.on.doc"
        case .video:    return "film"
        case .audio:    return "waveform"
        case .model3D:  return "cube.transparent"
        case .document: return "doc.text.fill"
        case .archive:  return "archivebox"
        case .design:   return "paintbrush.pointed"
        case .font:     return "textformat"
        case .installer: return "shippingbox"
        case .url:      return "link"
        case .json:     return "curlybraces"
        case .markdown: return "doc.plaintext"
        case .latex:    return "function"
        case .table:    return "tablecells"
        case .email:    return "envelope"
        case .phone:    return "phone"
        case .address:  return "mappin.and.ellipse"
        case .code:     return "chevron.left.forwardslash.chevron.right"
        case .color:    return "paintpalette"
        case .text:     return "doc.text"
        case .html:     return "globe"
        case .richText: return "doc.richtext"
        }
    }

    var badgeColor: Color {
        switch self {
        case .json:             return .green
        case .latex:            return .purple
        case .markdown:         return .indigo
        case .table:            return .mint
        case .email, .phone, .address: return .orange
        case .code:             return .blue
        case .url:              return .cyan
        case .image, .pdf, .svg: return .pink
        case .gif:               return .mint
        case .blob:              return .purple
        case .video, .audio:    return .teal
        case .model3D:          return .indigo
        case .document:         return .blue
        case .archive:          return .brown
        case .design:           return .pink
        case .font:             return .purple
        case .installer:        return .orange
        case .color:            return .yellow
        default:                return .gray
        }
    }

    static func from(_ type: ClipboardContentType) -> ClipboardTag? {
        switch type {
        case .plain:    return .text
        case .url:      return .url
        case .json:     return .json
        case .latex:    return .latex
        case .markdown: return .markdown
        case .table:    return .table
        case .email:    return .email
        case .phone:    return .phone
        case .address:  return .address
        case .code:     return .code
        case .hexColor: return .color
        }
    }
}

enum ItemTagStripStyle {
    case chips
    case plainComma
}

struct ItemTagStrip: View {
    let tags: [ClipboardTag]
    var maxVisible: Int = 4
    var compact: Bool = false
    var style: ItemTagStripStyle = .chips

    var body: some View {
        switch style {
        case .chips:
            chipStrip
        case .plainComma:
            plainCommaStrip
        }
    }

    private var chipStrip: some View {
        HStack(spacing: compact ? 4 : 5) {
            ForEach(Array(tags.prefix(maxVisible)), id: \.self) { tag in
                TagChip(tag: tag, compact: compact)
            }
            if tags.count > maxVisible {
                Text("+\(tags.count - maxVisible)")
                    .font(.system(size: compact ? 8 : 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
    }

    private var plainCommaStrip: some View {
        let visible = Array(tags.prefix(maxVisible))
        let labels = visible.map(\.label)
        let suffix = tags.count > maxVisible ? ", +\(tags.count - maxVisible)" : ""
        return Text(labels.joined(separator: ", ") + suffix)
            .font(.system(size: 9, weight: .medium))
            .foregroundColor(.secondary.opacity(0.72))
            .lineLimit(1)
    }
}

struct TagChip: View {
    let tag: ClipboardTag
    var compact: Bool = false

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: tag.icon)
                .font(.system(size: compact ? 8 : 9, weight: .semibold))
            Text(tag.label)
                .font(.system(size: compact ? 9 : 10, weight: .semibold))
        }
        .foregroundColor(tag.badgeColor)
        .padding(.horizontal, compact ? 6 : 7)
        .padding(.vertical, compact ? 2 : 3)
        .background(tag.badgeColor.opacity(0.14), in: Capsule())
        .overlay(Capsule().stroke(tag.badgeColor.opacity(0.35), lineWidth: 0.5))
    }
}
