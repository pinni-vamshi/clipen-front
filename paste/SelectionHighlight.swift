import SwiftUI

enum SelectionHighlightStyle {
    static let scale: CGFloat = 1.12
    static let cornerRadius: CGFloat = 8
    /// Corner radius of an image thumbnail inside a run (the clip shape on
    /// the picture itself, not the selection box around it).
    static let cellCornerRadius: CGFloat = 6
    static let spring = Animation.spring(response: 0.35, dampingFraction: 0.75)

    static let rowRailSpacing: CGFloat = 8

    static let rowInset: CGFloat = 23
}

enum SelectionHighlightAppearance {
    /// A whole row: the accent box fills the row and the row pops slightly.
    case row

    /// One member of a run — an image thumbnail or a short-text chip — which
    /// is selected on its own inside a row that holds several.
    ///
    /// This used to be three separate effects layered on top of each other:
    /// the run's whole ROW filled with accent (`.rowSurface`, with no shared
    /// geometry, so it faded in where it stood), a white ring springing in
    /// on the chosen image (`.cell`), and a `nil` transaction wrapped round
    /// the run that stopped either of them gliding. Stepping from a text row
    /// onto an image run therefore ran two unrelated animations at once —
    /// the normal rows' shared box faded out with nowhere to go, while the
    /// run's own fill and ring appeared by themselves — which is the
    /// "duplicated, coming back" look.
    ///
    /// Now there is exactly one selection box. A run member joins the same
    /// `matchedGeometryEffect` group the normal rows use, so the one box
    /// glides from a row, onto the chosen image or chip, along the run, and
    /// back out to the next row.
    ///
    /// `outset` grows the box past the member's own bounds without changing
    /// its layout size (an image needs room around it; a chip already
    /// carries its own padding). `radius` is set per member so the box stays
    /// concentric with a clipped thumbnail.
    case cellBox(outset: CGFloat, radius: CGFloat)
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

        case .cellBox(let outset, let radius):
            // Same chain, in the same order, as `.row` — fill, opacity,
            // matched geometry, shadow, then scale, then the spring bound to
            // `isSelected` last so it governs everything above it. The order
            // is what makes the glide animate: both ends of a move (the box
            // leaving one member, the box arriving at another) run under
            // their own member's spring.
            //
            // The negative padding sits BEFORE the matched-geometry modifier
            // so the group's frame is the grown box, not the bare member.
            content
                .background {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(Color.accentColor)
                        .padding(-outset)
                        .opacity(isSelected ? 1 : 0)
                        .matchedGeometryEffect(id: "selectionBox", in: namespace, isSource: isSelected)
                        .shadow(color: Color.accentColor.opacity(isSelected ? 0.22 : 0),
                                radius: isSelected ? 4 : 0, x: 0, y: isSelected ? 1.5 : 0)
                }
                .scaleEffect(isSelected ? SelectionHighlightStyle.scale : 1.0)
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
