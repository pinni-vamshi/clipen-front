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

        // +6 per gap between cards, matching the wider spacing between
        // sections (VStack spacing 16 vs. 10 before), and +26 rather than
        // +22 per extra field — each field row now carries its own small
        // vertical padding for the per-field selection/mark background.
        // The scroll view absorbs any remainder either way.
        let contentHeight: CGFloat = 46 + CGFloat(max(0, units.count - 1)) * 6
            + units.reduce(0) { partial, unit in
            switch unit.kind {
            case .single: return partial + 64
            case .group(_, let fields): return partial + 64 + CGFloat(max(0, fields.count - 1)) * 26
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

/// One navigable, pasteable stop inside the Details panel.
///
/// A `.single` unit is always exactly one stop. A `.group` — a section like
/// SENDER (name/email/phone) or one line item (item/cost) — used to be one
/// atomic stop: D landed on the whole card, and pasting always joined every
/// field in it, with no way to grab just the phone number back out. Now a
/// group expands into one stop per field, in order, FOLLOWED by one
/// whole-group stop: D visits NAME, then EMAIL, then PHONE, each pasting
/// just that value, and only after the last field does it land on the
/// section as a whole — pasting all of it joined, same as before. Fields
/// first, "grab it all" last, because by the time you've stepped past every
/// individual fact, the whole card is the natural next thing to want.
///
/// `detailsIndex` is an index into `DetailUnit.stops(for:)`, not into
/// `detailUnits` directly, everywhere it's used — cycling, marking,
/// reanchoring across a rebuild, and paste resolution. The unit list itself
/// (`detailUnits`) is untouched: this is purely a navigation/paste layer on
/// top of it, so nothing that addresses units by id, dedupes by value, or
/// decides what counts as a group has to change.
struct DetailStop: Equatable {
    let unitIndex: Int
    /// nil = the whole unit (paste = every field joined). Set = one field
    /// inside a `.group`, at this position in its `fields` array.
    let fieldIndex: Int?

    /// The value this stop pastes: one field's value, or the unit's full
    /// joined text when `fieldIndex` is nil.
    func text(in units: [DetailUnit]) -> String {
        guard units.indices.contains(unitIndex) else { return "" }
        let unit = units[unitIndex]
        if let f = fieldIndex, case .group(_, let fields) = unit.kind, fields.indices.contains(f) {
            return fields[f].value
        }
        return unit.pasteText
    }
}

extension DetailUnit {
    /// Expands a unit list into its full stop sequence. A `.single` unit
    /// contributes one stop; a `.group` with N fields contributes N field
    /// stops followed by one whole-group stop, in that order.
    static func stops(for units: [DetailUnit]) -> [DetailStop] {
        var out: [DetailStop] = []
        for (i, unit) in units.enumerated() {
            switch unit.kind {
            case .single:
                out.append(DetailStop(unitIndex: i, fieldIndex: nil))
            case .group(_, let fields):
                for f in fields.indices { out.append(DetailStop(unitIndex: i, fieldIndex: f)) }
                out.append(DetailStop(unitIndex: i, fieldIndex: nil))
            }
        }
        return out
    }
}

struct DetailsPanelView: View {
    let units: [DetailUnit]
    /// Index into `DetailUnit.stops(for: units)`, NOT into `units` — a
    /// group's fields and its own whole-section row are each their own
    /// stop. See `DetailStop`.
    let selectedIndex: Int
    /// Also stop-indexed: a mark on one field inside a group and a mark on
    /// that group's whole-section stop are two different keys here.
    let markOrders: [Int: Int]
    /// The AI pass is still running underneath the instantly-available
    /// system-detected rows. Shown as a footer rather than replacing the
    /// list, because the list is already usable while it runs.
    var analyzing: Bool = false

    @Namespace private var selectionNamespace

    private static let horizontalInset: CGFloat = 16

    private var combinedMode: Bool { units.contains { $0.sourceLabel != nil } }

    /// Pure function of `units`, recomputed rather than threaded in
    /// separately — the call site already has to keep `selectedIndex` and
    /// `markOrders` in sync with this same expansion, so deriving it here
    /// instead of passing a third parallel array removes one more thing
    /// that could drift out of sync with `units`.
    private var stops: [DetailStop] { DetailUnit.stops(for: units) }

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
            let stops = self.stops
            ScrollViewReader { proxy in
                ScrollView {
                    // A touch more room between cards than between the
                    // fields inside one (10 -> 16) — each section should
                    // read as its own block, not run into the next.
                    VStack(spacing: 16) {
                        ForEach(units.indices, id: \.self) { idx in
                            let unit = units[idx]

                            // Which stop of THIS unit (if any) currently
                            // has the cursor. nil field index while
                            // wholeSelected means D has landed on the
                            // whole-section stop; a non-nil field index
                            // means it's on one field inside the group,
                            // and the card itself stays at rest while just
                            // that line lights up.
                            let isFocusedHere = stops.indices.contains(selectedIndex)
                                && stops[selectedIndex].unitIndex == idx
                            let focusedFieldIndex = isFocusedHere ? stops[selectedIndex].fieldIndex : nil
                            let wholeSelected = isFocusedHere && focusedFieldIndex == nil

                            let stopIndex: (Int?) -> Int? = { field in
                                stops.firstIndex(where: { $0.unitIndex == idx && $0.fieldIndex == field })
                            }
                            let wholeMarkOrder = stopIndex(nil).flatMap { markOrders[$0] }

                            VStack(alignment: .leading, spacing: 4) {
                                if let source = unit.sourceLabel {
                                    Text(source.uppercased())
                                        .font(.system(size: 8, weight: .bold)).tracking(0.5)
                                        .foregroundColor(wholeSelected ? .white.opacity(0.55) : .accentColor.opacity(0.8))
                                }
                                unitRow(unit, wholeSelected: wholeSelected,
                                       focusedFieldIndex: focusedFieldIndex,
                                       wholeMarkOrder: wholeMarkOrder,
                                       fieldMarkOrder: { fi in stopIndex(fi).flatMap { markOrders[$0] } })
                            }
                            .transaction { $0.animation = nil }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .selectionHighlight(isSelected: wholeSelected,
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
                    guard stops.indices.contains(new) else { return }
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(stops[new].unitIndex, anchor: .center)
                    }
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
    private func unitRow(_ unit: DetailUnit, wholeSelected: Bool, focusedFieldIndex: Int?,
                          wholeMarkOrder: Int?, fieldMarkOrder: @escaping (Int) -> Int?) -> some View {
        HStack(alignment: .top, spacing: 10) {
            switch unit.kind {
            case .single(let field):
                VStack(alignment: .leading, spacing: 3) {
                    Text(field.key.uppercased())
                        .font(.system(size: 9, weight: .semibold)).tracking(0.7)
                        .foregroundColor(wholeSelected ? .white.opacity(0.75) : .secondary)
                    Text(field.value)
                        .font(.system(size: 12, weight: wholeSelected ? .semibold : .regular))
                        .foregroundColor(wholeSelected ? .white : .primary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

            case .group(let key, let fields):

                VStack(alignment: .leading, spacing: 6) {
                    Text(key.uppercased())
                        .font(.system(size: 9, weight: .bold)).tracking(0.7)
                        .foregroundColor(wholeSelected ? .white.opacity(0.75) : .secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(fields.indices, id: \.self) { fi in
                            let field = fields[fi]
                            // Highlighted either because D has stepped onto
                            // THIS field specifically, or because the whole
                            // section is selected — in which case every
                            // field lights up together, same look as before
                            // this change.
                            let fieldFocused = wholeSelected || focusedFieldIndex == fi
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(field.key.uppercased())
                                    .font(.system(size: 8, weight: .semibold)).tracking(0.4)
                                    .foregroundColor(fieldFocused ? .white.opacity(0.55) : .secondary.opacity(0.8))
                                    .frame(width: 78, alignment: .leading)
                                Text(field.value)
                                    .font(.system(size: 12, weight: fieldFocused ? .semibold : .regular))
                                    .foregroundColor(fieldFocused ? .white : .primary)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                                if let order = fieldMarkOrder(fi) {
                                    markBadge(order, onWhite: fieldFocused)
                                }
                            }
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(
                                // Only a field selected on its OWN gets this
                                // pill — the whole-section highlight already
                                // covers the entire card via
                                // .selectionHighlight above, so drawing this
                                // too would double up the same state.
                                (focusedFieldIndex == fi && !wholeSelected)
                                    ? Color.accentColor.opacity(0.85) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                            )
                        }
                    }
                }
            }

            Spacer(minLength: 0)
            if let order = wholeMarkOrder {
                markBadge(order, onWhite: wholeSelected)
            }
        }
    }

    private func markBadge(_ order: Int, onWhite: Bool) -> some View {
        Text("\(order)")
            .font(.system(size: 9, weight: .bold))
            .foregroundColor(onWhite ? .accentColor : .white)
            .frame(width: 16, height: 16)
            .background(onWhite ? Color.white : Color.accentColor, in: Circle())
    }
}
