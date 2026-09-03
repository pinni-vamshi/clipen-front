import AppKit
import SwiftUI

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

    let markOrder: Int?

    private static let blue = Color(hex: "#4F8EF7")

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
