import AppKit
import SwiftUI

/// Mirrors ItemPreviewPanel's architecture and exact box size (same
/// anchored NSPopover strip beside the popup row, same 520x420 content
/// area, same ContentPreviewView renderer) but drives its own cursor
/// through the list of related items instead of showing the selected
/// clipboard item directly. Each R/Shift+R press swaps which related item
/// fills the box — the box itself never changes shape, so a related item
/// previews exactly like viewing it directly would.
class SimilarPanel: AnchoredPopoverPanel {
    func show(sourceItem: ClipboardItem,
              items: [ClipboardItem],
              selectedIndex: Int,
              markOrder: Int?,
              near popupFrame: NSRect,
              anchorPoint: NSPoint? = nil) {

        let content = SimilarPanelView(
            items: items,
            selectedIndex: selectedIndex,
            markOrder: markOrder
        )

        let w: CGFloat = 520
        let h: CGFloat = 420
        present(content, size: NSSize(width: w, height: h),
                near: popupFrame, anchorPoint: anchorPoint)
    }
}

struct SimilarPanelView: View {
    let items:         [ClipboardItem]
    let selectedIndex: Int
    // Passed in rather than read from ClipboardManager.shared inside body
    // — a global read is invisible to SwiftUI's diffing, so marking the
    // CURRENTLY displayed item (items/selectedIndex unchanged) never
    // triggered a re-render; an explicit prop does, same pattern
    // PopoverRow already uses for the main list's own mark badges.
    let markOrder: Int?

    private static let blue = Color(hex: "#4F8EF7")

    /// Same badge the content preview's corner overlay uses — factored out
    /// so the title bar can show the exact same number rather than a
    /// second, differently-styled indicator. Navigating fast with R means
    /// the eye is already on the title row (that's where "N of M" lives),
    /// not the corner of a 520x420 preview — the corner badge alone made it
    /// too easy to cycle past a marked item without noticing it was marked.
    private static func markBadge(_ order: Int) -> some View {
        Text("\(order)")
            .font(.system(size: 9, weight: .black))
            .foregroundColor(.white)
            .frame(width: 16, height: 16)
            .background(Color(red: 0.20, green: 0.78, blue: 0.35), in: Circle())
    }

    private var currentItem: ClipboardItem? {
        items.indices.contains(selectedIndex) ? items[selectedIndex] : nil
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let item = currentItem {
                ContentPreviewView(item: item, chrome: .panel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(14)
            } else {
                emptyState
            }
        }
    }

    // Title sits at the leading edge; the "N of M" count is centered on
    // the header's own midline (not just right-of-title) — a ZStack keeps
    // it truly centered regardless of how long the title or hints are.
    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                Text(items.isEmpty ? "" : "\(selectedIndex + 1) of \(items.count)")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(Self.blue)

                HStack(spacing: 6) {
                    Image(systemName: "sparkle.magnifyingglass")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                    Text("Similar items")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    // After the Spacer, not before — the Spacer eats
                    // whatever width is left, so a badge placed ahead of
                    // it (the old position) stays glued next to the
                    // title text instead of reaching the far right edge.
                    if let order = markOrder {
                        Self.markBadge(order)
                            .help("Marked #\(order) for multi-paste — hold R to toggle")
                    }
                }
            }
            HStack(spacing: 14) {
                FlatHint(key: "R", label: "Next")
                FlatHint(key: "⇧R", label: "Prev")
                FlatHint(key: "hold R", label: "Mark")
                FlatHint(key: "↵", label: "Paste")
                Spacer()
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "sparkle.magnifyingglass")
                .font(.system(size: 24, weight: .thin))
                .foregroundColor(.secondary.opacity(0.4))
            Text("No similar items found")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary.opacity(0.6))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
