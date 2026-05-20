import AppKit
import SwiftUI

enum ClipboardContentType {
    case plain
    case url
    case json
    case latex
    case markdown
    case table(String)
    case email
    case phone
    case address
    case code(String)
    case hexColor(NSColor)

    var badgeLabel: String? {
        switch self {
        case .plain, .hexColor: return nil
        case .url:              return "URL"
        case .json:             return "JSON"
        case .latex:            return "LaTeX"
        case .markdown:         return "MD"
        case .table(let kind):   return kind
        case .email:            return "Email"
        case .phone:            return "Phone"
        case .address:          return "Address"
        case .code(let lang):   return lang
        }
    }

    var sfIcon: String {
        switch self {
        case .plain:    return "doc.text"
        case .url:      return "link"
        case .json:     return "curlybraces"
        case .latex:    return "function"
        case .markdown: return "doc.plaintext"
        case .table:    return "tablecells"
        case .email:    return "envelope"
        case .phone:    return "phone"
        case .address:  return "mappin.and.ellipse"
        case .code:     return "chevron.left.forwardslash.chevron.right"
        case .hexColor: return "paintpalette"
        }
    }

    var badgeColor: Color {
        switch self {
        case .json:             return .green
        case .latex:            return .purple
        case .markdown:         return .indigo
        case .table:            return .mint
        case .email, .phone,
             .address:          return .orange
        case .code:             return .blue
        case .url:              return .cyan
        default:                return .gray
        }
    }
}
