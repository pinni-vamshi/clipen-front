import AppKit
import SwiftUI

class DetailsPanel: AnchoredPopoverPanel {
    func show(units: [DetailUnit],
              selectedIndex: Int,
              markOrders: [Int: Int],
              analyzing: Bool = false,
              near popupFrame: NSRect,
              anchorPoint: NSPoint? = nil) {

        let content = DetailsPanelView(units: units, selectedIndex: selectedIndex,
                                       markOrders: markOrders, analyzing: analyzing)

        let w: CGFloat = 400
        let minHeight: CGFloat = 160
        let maxHeight: CGFloat = 480

        let contentHeight: CGFloat = 46 + units.reduce(0) { partial, unit in
            switch unit.kind {
            case .single: return partial + 64
            case .group(_, let fields): return partial + 64 + CGFloat(max(0, fields.count - 1)) * 22
            }
        }
        let h: CGFloat = min(maxHeight, max(minHeight, contentHeight + (analyzing ? 24 : 0)))
        present(content, size: NSSize(width: w, height: h),
                near: popupFrame, anchorPoint: anchorPoint)
    }
}

struct DetailField: Equatable, Identifiable {
    let key: String
    let value: String
    var id: String { key + "\u{1}" + value }
}

struct DetailUnit: Equatable, Identifiable {
    enum Kind: Equatable {
        case single(DetailField)
        case group(key: String, fields: [DetailField])
    }
    let kind: Kind

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

    var pasteText: String {
        switch kind {
        case .single(let f): return f.value
        case .group(_, let fields): return fields.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
        }
    }

    /// Every value this unit carries, used to decide whether a
    /// system-detected field is already covered by an AI-extracted one.
    var detailValues: [String] {
        switch kind {
        case .single(let f): return [f.value]
        case .group(_, let fields): return fields.map(\.value)
        }
    }

    /// Dedupe identity for a value across the two extraction layers.
    /// Compared on alphanumerics only so the same fact written two ways —
    /// "+1 (555) 123-4567" by NSDataDetector and "15551234567" by the model
    /// — collapses to one row instead of appearing twice.
    static func valueIdentity(_ value: String) -> String {
        String(value.lowercased().unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        }.map(Character.init))
    }
}

struct DetailsPanelView: View {
    let units: [DetailUnit]
    let selectedIndex: Int
    let markOrders: [Int: Int]
    /// The AI pass is still running underneath the instantly-available
    /// system-detected rows. Shown as a footer rather than replacing the
    /// list, because the list is already usable while it runs.
    var analyzing: Bool = false

    @Namespace private var selectionNamespace

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

            if units.isEmpty {
                // Shown while browsing lands on an item with no analysis.
                // The panel deliberately stays open in this state rather
                // than collapsing, so navigating past a gap doesn't drop
                // the user out of the Details flow.
                VStack(spacing: 4) {
                    Text("No analysis for this item yet")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.textDim)
                    Text("Keep browsing, or wait a moment while it's analyzed")
                        .font(.system(size: 9))
                        .foregroundColor(.textDim.opacity(0.7))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
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

            if analyzing { analyzingFooter }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Sits under the rows, never over them: the system-detected rows above
    /// are already selectable and pasteable, so this is a promise of MORE
    /// coming, not a blocking spinner.
    private var analyzingFooter: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.55)
                .frame(width: 10, height: 10)
            Text(units.isEmpty ? "Analyzing\u{2026}" : "Analyzing for more\u{2026}")
                .font(.system(size: 9, weight: .medium)).tracking(0.4)
                .foregroundColor(.textDim)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.10))
        .overlay(Divider().background(Color.border), alignment: .top)
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
