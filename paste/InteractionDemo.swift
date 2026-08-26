import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

enum InteractionDemo: String, CaseIterable, Identifiable {
    case cycle, pinnedOpen, multiPaste, search, nextCategory
    case spacePreview, pinPreview, transform, similar, moveToFront, delete, reverseCycle
    case cyclePinned, pinItem, group, collections

    case pasteOne, pasteTwo, pasteThree

    var id: String { rawValue }

    var keyLabel: String {
        switch self {
        case .cycle:        return "⌘ + tap V"
        case .pinnedOpen:   return "⌘ + hold V"
        case .multiPaste:   return "hold V"
        case .search:       return "tap F"
        case .nextCategory: return "tap `"
        case .spacePreview: return "tap ␣"
        case .pinPreview:   return "tap ␣ ×2"
        case .transform:    return "tap X"
        case .similar:      return "tap R"
        case .moveToFront:  return "tap C"
        case .delete:       return "tap ⌫"
        case .reverseCycle: return "⇧ + tap V"
        case .cyclePinned:  return "tap P"
        case .pinItem:      return "hold P"
        case .group:        return "hold V → G"
        case .collections:  return "⌘ + V → 1 – 9"
        case .pasteOne:     return "⌘ + tap V"
        case .pasteTwo:     return "⌘ + V ×2"
        case .pasteThree:   return "⌘ + V ×3"
        }
    }

    var title: String {
        switch self {
        case .cycle:        return "Open / Next Item"
        case .pinnedOpen:   return "Open Pinned"
        case .multiPaste:   return "Mark for Multi-Paste"
        case .search:       return "Search"
        case .nextCategory: return "Next Category"
        case .spacePreview: return "Preview"
        case .pinPreview:   return "Refer (Pin Preview)"
        case .transform:    return "Transform"
        case .similar:      return "Find Similar"
        case .moveToFront:  return "Move to Front"
        case .delete:       return "Delete"
        case .reverseCycle: return "Previous Item"
        case .cyclePinned:  return "Cycle Pinned"
        case .pinItem:      return "Pin / Unpin"
        case .group:        return "Group Marked"
        case .collections:  return "Switch Collection"
        case .pasteOne:     return "Paste 1st Item"
        case .pasteTwo:     return "Paste 2nd Item"
        case .pasteThree:   return "Paste 3rd Item"
        }
    }

    var caption: String {
        switch self {
        case .cycle:        return "Hold ⌘ and tap V to open the popup; each tap moves to the next item.\nRelease ⌘ to paste the highlighted item."
        case .pinnedOpen:   return "HOLD V on the very first press — the popup opens pinned.\nReleasing ⌘ keeps it open; click ✕ or press Esc to close."
        case .multiPaste:   return "With the popup open, HOLD V to mark the highlighted item.\nRelease ⌘ to paste every marked item, in marking order."
        case .search:       return "Tap F while the popup is open to enter search mode.\nType to filter the list by contents."
        case .nextCategory: return "Tap ` to step to the next category one at a time.\nKeeps going through each category and wraps back to Recents."
        case .spacePreview: return "Tap Space to preview the highlighted item full-size.\nTap Space again to close — nothing is pasted."
        case .pinPreview:   return "Double-tap Space on the highlighted item.\nSends it to the Reference panel — the popup closes, the preview stays."
        case .transform:    return "Tap X to open the tools, tap X again to cycle them.\n⇧X steps back · hold X closes · release ⌘ pastes the result."
        case .similar:      return "Tap R to open related items for the highlighted one.\nKeep tapping R to step through each match found."
        case .moveToFront:  return "Tap C to move the highlighted item to the front of the ring.\nThe selection stays put — keep tapping C to promote a run of items."
        case .delete:       return "Tap ⌫ to remove the highlighted item from the ring.\nThe next item slides into its place."
        case .reverseCycle: return "Hold ⌘ and tap ⇧V.\nMoves to the previous item instead of the next."
        case .cyclePinned:  return "Tap P to jump between PINNED items only, wrapping at the end.\nUnpinned items in between are skipped entirely."
        case .pinItem:      return "HOLD P to pin the highlighted item (or unpin it if already pinned).\nUp to 5 items can be pinned at once."
        case .group:        return "Mark a few items (hold V on each), then tap G.\nThey fold into one group at the first-marked spot — paste, share or ungroup it as one."
        case .collections:  return "Hold ⌘ and tap V to open the ring, then press 1 for All — your whole clipboard — or 2 onward for each collection you created.\nThe ring switches to that view instantly."
        case .pasteOne:     return "Hold ⌘ and tap V once to land on the top item.\nRelease ⌘ to paste it."
        case .pasteTwo:     return "Hold ⌘ and tap V twice to reach the second item.\nRelease ⌘ to paste it."
        case .pasteThree:   return "Hold ⌘ and tap V three times to reach the third item.\nRelease ⌘ to paste it."
        }
    }

    var heroKeys: [LabKey] {
        switch self {
        case .cycle:        return [.cmd, .v]
        case .pinnedOpen:   return [.v]
        case .multiPaste:   return [.cmd, .v]
        case .search:       return [.cmd, .f]
        case .nextCategory: return [.cmd, .grave]
        case .spacePreview: return [.cmd, .space]
        case .pinPreview:   return [.cmd, .space]
        case .transform:    return [.cmd, .x]
        case .similar:      return [.cmd, .r]
        case .moveToFront:  return [.cmd, .c]
        case .delete:       return [.cmd, .backspace]
        case .reverseCycle: return [.cmd, .shift, .v]
        case .cyclePinned:  return [.cmd, .v, .p]
        case .pinItem:      return [.cmd, .v, .p]
        case .group:        return [.cmd, .v, .g]
        case .collections:  return [.cmd, .v, .one, .two]
        case .pasteOne, .pasteTwo, .pasteThree: return [.cmd, .v]
        }
    }
}

enum LabKey: String, Identifiable, Hashable {
    case cmd, v, x, f, c, b, p, g, r, shift, space, backspace, one, two, grave

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .cmd:       return "⌘"
        case .v:         return "V"
        case .x:         return "X"
        case .f:         return "F"
        case .c:         return "C"
        case .b:         return "B"
        case .p:         return "P"
        case .g:         return "G"
        case .r:         return "R"
        case .shift:     return "⇧"
        case .space:     return "SPACE"
        case .backspace: return "⌫"
        case .one:       return "1"
        case .two:       return "2"
        case .grave:     return "`"
        }
    }

    var isWide: Bool { self == .space }

    var kbKeyIDs: [String] {
        switch self {
        case .cmd:       return ["LCMD"]
        case .v:         return ["V"]
        case .x:         return ["X"]
        case .f:         return ["F"]
        case .c:         return ["C"]
        case .b:         return ["B"]
        case .p:         return ["P"]
        case .g:         return ["G"]
        case .r:         return ["R"]
        case .shift:     return ["LSHIFT", "RSHIFT"]
        case .space:     return ["SPACE"]
        case .backspace: return ["DELETE"]
        case .one:       return ["1"]
        case .two:       return ["2"]
        case .grave:     return ["GRAVE"]
        }
    }
}
