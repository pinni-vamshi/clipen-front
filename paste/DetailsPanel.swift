import AppKit
import SwiftUI

/// One row per unit of the selected item's AI-structured JSON, with its
/// own cursor driven by repeated D presses — the same shape as the
/// Transform and Similar panels.
///
/// A unit is either a single leaf value, or — when a nested object's
/// direct children are all scalars (an address, a name, an amount+currency
/// pair) — a whole GROUP shown together, so the user navigates by
/// hierarchy rather than being forced through every sub-field one at a
/// time. Arrays of repeated objects (line items, steps) still flatten to
/// individual leaves, since those genuinely read better one at a time.
///
/// The point is granular pasting: releasing Command pastes just the
/// highlighted unit's value ("9032930998", or a whole address as one
/// readable block) instead of the whole captured item or the whole JSON
/// blob.
class DetailsPanel: AnchoredPopoverPanel {
    func show(units: [DetailUnit],
              selectedIndex: Int,
              markOrders: [Int: Int],
              near popupFrame: NSRect,
              anchorPoint: NSPoint? = nil) {

        let content = DetailsPanelView(units: units, selectedIndex: selectedIndex,
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
        // ~46 for the fixed header + list padding, ~64 per single-field row,
        // groups add ~22 per extra sub-field on top of their own base row —
        // measured against this view's own padding/spacing constants below,
        // not guessed.
        let contentHeight: CGFloat = 46 + units.reduce(0) { partial, unit in
            switch unit.kind {
            case .single: return partial + 64
            case .group(_, let fields): return partial + 64 + CGFloat(max(0, fields.count - 1)) * 22
            }
        }
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

/// One navigable stop in the Details panel — either a lone value, or a
/// whole flat cluster of a nested object's scalar children shown together.
struct DetailUnit: Equatable, Identifiable {
    enum Kind: Equatable {
        case single(DetailField)
        case group(key: String, fields: [DetailField])
    }
    let kind: Kind
    /// Which item this came from, shown only when several marked items'
    /// details are combined into one panel — nil in the ordinary
    /// single-item case, where it would just be redundant chrome.
    let sourceLabel: String?

    init(_ kind: Kind, sourceLabel: String? = nil) {
        self.kind = kind
        self.sourceLabel = sourceLabel
    }

    var id: String {
        let base: String
        switch kind {
        case .single(let f): base = f.id
        case .group(let key, let fields): base = key + "\u{1}" + fields.map(\.id).joined(separator: "\u{1}")
        }
        return (sourceLabel ?? "") + "\u{2}" + base
    }

    var headingKey: String {
        switch kind {
        case .single(let f): return f.key
        case .group(let key, _): return key
        }
    }

    /// What gets pasted — a single field's own value, or a group's fields
    /// joined as readable "Key: Value" lines, so pasting an address (say)
    /// produces the whole thing as one block, not just its first field.
    var pasteText: String {
        switch kind {
        case .single(let f): return f.value
        case .group(_, let fields): return fields.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
        }
    }
}

struct DetailsPanelView: View {
    let units: [DetailUnit]
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

    private var combinedMode: Bool { units.contains { $0.sourceLabel != nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: 10, weight: .semibold)).foregroundColor(.textDim)
                Text(combinedMode ? "DETAILS \u{00B7} \(Set(units.compactMap(\.sourceLabel)).count) ITEMS" : "DETAILS")
                    .font(.system(size: 9, weight: .semibold)).tracking(1.6)
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
                        ForEach(units.indices, id: \.self) { idx in
                            let unit = units[idx]
                            let selected = idx == selectedIndex
                            let markOrder = markOrders[idx]

                            VStack(alignment: .leading, spacing: 4) {
                                if let source = unit.sourceLabel {
                                    Text(source.uppercased())
                                        .font(.system(size: 8, weight: .bold)).tracking(0.5)
                                        .foregroundColor(selected ? .white.opacity(0.55) : .accentColor.opacity(0.8))
                                }
                                unitRow(unit, selected: selected, markOrder: markOrder)
                            }
                            .transaction { $0.animation = nil }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .selectionHighlight(isSelected: selected,
                                                namespace: selectionNamespace,
                                                inset: Self.horizontalInset)
                            .id(idx)

                            if idx < units.count - 1 {
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

    @ViewBuilder
    private func unitRow(_ unit: DetailUnit, selected: Bool, markOrder: Int?) -> some View {
        HStack(alignment: .top, spacing: 10) {
            switch unit.kind {
            case .single(let field):
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

            case .group(let key, let fields):
                // The whole group is ONE navigable stop — the cursor lands
                // on the group, not on any one sub-field — but every
                // sub-field's key AND value are visible together, which is
                // the entire point: an address (say) reads as one thing.
                VStack(alignment: .leading, spacing: 6) {
                    Text(key.uppercased())
                        .font(.system(size: 9, weight: .bold)).tracking(0.7)
                        .foregroundColor(selected ? .white.opacity(0.75) : .secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(fields) { field in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(field.key.uppercased())
                                    .font(.system(size: 8, weight: .semibold)).tracking(0.4)
                                    .foregroundColor(selected ? .white.opacity(0.55) : .secondary.opacity(0.8))
                                    .frame(width: 78, alignment: .leading)
                                Text(field.value)
                                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                                    .foregroundColor(selected ? .white : .primary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
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
    }
}
