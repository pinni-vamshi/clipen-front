import SwiftUI

enum SelectionHighlightStyle {
    static let scale: CGFloat = 1.12
    static let cellScale: CGFloat = 1.22
    static let cornerRadius: CGFloat = 8
    static let cellCornerRadius: CGFloat = 6
    static let cellBorderWidth: CGFloat = 4.0
    static let spring = Animation.spring(response: 0.35, dampingFraction: 0.75)
    /// Rail → divider → content spacing, shared by every row type
    /// (PopoverRow, ImageRunRow) so the divider lands at the same x
    /// position regardless of which kind of row it belongs to. Keep this
    /// independent from any row type's own internal content spacing
    /// (e.g. ImageRunRow.cellGap) — that one broke this exact alignment
    /// once already by being reused for both.
    static let rowRailSpacing: CGFloat = 8
    /// Outer horizontal inset every row type sits behind, so each row's
    /// rail and divider land at the same x. Lives here rather than on one
    /// row type because ImageRunRow not having it is what pushed image
    /// rows 23pt left of everything else — and, once they gained a scale
    /// effect, made them overflow the popup's fixed width when selected.
    static let rowInset: CGFloat = 23
}

enum SelectionHighlightAppearance {
    case row
    /// Same geometry as `.row` — same inset, same scale, same spring — but
    /// a transparent raised surface instead of the accent fill. For rows
    /// whose *contents* already carry their own per-item highlight (image
    /// runs), where an opaque blue wash would bury the images and a second
    /// accent-coloured box would compete with the cell borders.
    case rowSurface
    case cell
}

struct SelectionHighlight: ViewModifier {
    let isSelected: Bool
    let namespace: Namespace.ID

    let inset: CGFloat
    var appearance: SelectionHighlightAppearance = .row

    func body(content: Content) -> some View {
        switch appearance {
        case .row:
            content
                .background {
                    RoundedRectangle(cornerRadius: SelectionHighlightStyle.cornerRadius, style: .continuous)
                        .fill(Color.accentColor)
                        .opacity(isSelected ? 1 : 0)
                        .matchedGeometryEffect(id: "selectionBox", in: namespace, isSource: isSelected)

                        .shadow(color: Color.accentColor.opacity(isSelected ? 0.22 : 0),
                                radius: isSelected ? 4 : 0, x: 0, y: isSelected ? 1.5 : 0)
                }
                .padding(.horizontal, inset)

                .scaleEffect(isSelected ? SelectionHighlightStyle.scale : 1.0)
                .animation(SelectionHighlightStyle.spring, value: isSelected)
        case .rowSurface:
            content
                .background {
                    RoundedRectangle(cornerRadius: SelectionHighlightStyle.cornerRadius, style: .continuous)
                        .fill(Color.accentColor)
                        .opacity(isSelected ? 1 : 0)
                        // Deliberately no matchedGeometryEffect: the cells
                        // inside this row already drive "selectionBox", and
                        // a second source for the same id while one of them
                        // is selected breaks the shared animation. This
                        // surface fades and scales in place instead.
                        .shadow(color: Color.accentColor.opacity(isSelected ? 0.22 : 0),
                                radius: isSelected ? 4 : 0, x: 0, y: isSelected ? 1.5 : 0)
                }
                .padding(.horizontal, inset)
                .scaleEffect(isSelected ? SelectionHighlightStyle.scale : 1.0)
                .animation(SelectionHighlightStyle.spring, value: isSelected)
        case .cell:
            content
                .overlay {
                    RoundedRectangle(cornerRadius: SelectionHighlightStyle.cellCornerRadius, style: .continuous)
                        .stroke(.ultraThinMaterial, lineWidth: SelectionHighlightStyle.cellBorderWidth)
                        .opacity(isSelected ? 1 : 0)
                        // Separate id from .row/.rowSurface's "selectionBox"
                        // on purpose: they used to share one, which made
                        // SwiftUI try to morph a small outlined thumbnail
                        // border into a large filled row rectangle (or the
                        // reverse) whenever selection moved between an image
                        // run and any other row — two structurally unrelated
                        // shapes tweening into each other, which read as
                        // stutter rather than a clean transition. Each family
                        // now animates independently.
                        .matchedGeometryEffect(id: "selectionBoxCell", in: namespace, isSource: isSelected)
                        .shadow(color: Color.black.opacity(isSelected ? 0.3 : 0),
                                radius: isSelected ? 6 : 0, x: 0, y: isSelected ? 2 : 0)
                }
                // A stronger pop than a row's own scale — images sit in
                // tight horizontal runs, so the selected one needs a
                // bigger lift to read clearly against its neighbors.
                .scaleEffect(isSelected ? SelectionHighlightStyle.cellScale : 1.0)
                .animation(SelectionHighlightStyle.spring, value: isSelected)
        }
    }
}

extension View {

    func selectionHighlight(isSelected: Bool, namespace: Namespace.ID,
                             inset: CGFloat, appearance: SelectionHighlightAppearance = .row) -> some View {
        modifier(SelectionHighlight(isSelected: isSelected, namespace: namespace,
                                     inset: inset, appearance: appearance))
    }
}
