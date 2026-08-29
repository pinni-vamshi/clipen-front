import AppKit
import SwiftUI

/// One row per field of the selected item's AI-structured JSON, with its
/// own cursor driven by repeated D presses — the same shape as the
/// Transform and Similar panels.
///
/// The point is granular pasting: releasing Command pastes just the
/// highlighted field's value ("9032930998") instead of the whole captured
/// item or the whole JSON blob.
class DetailsPanel: AnchoredPopoverPanel {
    func show(fields: [DetailField],
              selectedIndex: Int,
              markOrders: [Int: Int],
              near popupFrame: NSRect,
              anchorPoint: NSPoint? = nil) {

        let content = DetailsPanelView(fields: fields, selectedIndex: selectedIndex,
                                       markOrders: markOrders)

        // Narrower and shorter than the Similar box: this is a list of short
        // key/value rows, not a full content preview. Height is dynamic
        // between a floor and a ceiling — never so short a single field
        // looks cramped against the header, never so tall a long list
        // overruns the screen (it scrolls past the ceiling instead, same
        // as it already did before this had bounds at all).
        let w: CGFloat = 400
        let minHeight: CGFloat = 160
        let maxHeight: CGFloat = 480
        // ~46 for the fixed header + list padding, ~64 per row (row content
        // plus its divider and inter-row spacing) — measured against this
        // view's own padding/spacing constants below, not guessed.
        let contentHeight: CGFloat = 46 + CGFloat(fields.count) * 64
        let h: CGFloat = min(maxHeight, max(minHeight, contentHeight))
        present(content, size: NSSize(width: w, height: h),
                near: popupFrame, anchorPoint: anchorPoint)
    }
}


/// A single flattened key/value pair from the item's AI JSON.
struct DetailField: Equatable, Identifiable {
    let key: String
    let value: String
    var id: String { key + "\u{1}" + value }
}

struct DetailsPanelView: View {
    let fields: [DetailField]
    let selectedIndex: Int
    let markOrders: [Int: Int]

    /// The popup's own selection namespace type — using the shared
    /// `.selectionHighlight` modifier means this panel gets the identical
    /// blue fill, corner radius, scale and spring as every other row in the
    /// app, rather than a lookalike that drifts out of sync when the shared
    /// style is tuned.
    @Namespace private var selectionNamespace
    /// The app-wide row inset, not a local guess. `.row` insets by this and
    /// THEN scales 1.12, so too small an inset makes the scaled box overrun
    /// the panel's edges and clip its own corners — which is exactly what a
    /// hand-picked 6 did here. Using the shared constant keeps this panel
    /// geometrically identical to the popup rows.
    private static let horizontalInset: CGFloat = 16

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: 10, weight: .semibold)).foregroundColor(.textDim)
                Text("DETAILS").font(.system(size: 9, weight: .semibold)).tracking(1.6)
                    .foregroundColor(.textDim)
                Spacer()
                Text("D / \u{21E7}D \u{00B7} hold D marks \u{00B7} release \u{2318} to paste")
                    .font(.system(size: 8)).foregroundColor(.textDim.opacity(0.6))
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider().background(Color.border)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(fields.indices, id: \.self) { idx in
                            let field = fields[idx]
                            let selected = idx == selectedIndex
                            let markOrder = markOrders[idx]
                            HStack(alignment: .top, spacing: 10) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(field.key.uppercased())
                                        .font(.system(size: 9, weight: .semibold)).tracking(0.7)
                                        .foregroundColor(selected ? .white.opacity(0.75) : .secondary)
                                    Text(field.value)
                                        .font(.system(size: 12, weight: selected ? .semibold : .regular))
                                        .foregroundColor(selected ? .white : .primary)
                                        .lineLimit(2)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 0)
                                if let order = markOrder {
                                    Text("\(order)")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundColor(selected ? .accentColor : .white)
                                        .frame(width: 16, height: 16)
                                        .background(selected ? Color.white : Color.accentColor, in: Circle())
                                }
                            }
                            .transaction { $0.animation = nil }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .selectionHighlight(isSelected: selected,
                                                namespace: selectionNamespace,
                                                inset: Self.horizontalInset)
                            .id(idx)

                            if idx < fields.count - 1 {
                                Divider().padding(.leading, 36)
                            }
                        }
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)
                }
                .onChange(of: selectedIndex) { _, new in
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(new, anchor: .center) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
