import SwiftUI

enum SelectionHighlightStyle {
    static let scale: CGFloat = 1.12
    static let cellScale: CGFloat = 1.22
    static let cornerRadius: CGFloat = 8
    static let cellCornerRadius: CGFloat = 6
    static let cellBorderWidth: CGFloat = 4.0
    /// Thin enough to sit around text without crowding it — see
    /// `SelectionHighlightAppearance.textCell`.
    static let textCellBorderWidth: CGFloat = 1.5
    static let spring = Animation.spring(response: 0.35, dampingFraction: 0.75)

    static let rowRailSpacing: CGFloat = 8

    static let rowInset: CGFloat = 23
}

enum SelectionHighlightAppearance {
    case row

    case rowSurface
    case cell
    /// The `.cell` treatment retuned for text rather than a thumbnail.
    ///
    /// `.cell` is built for a 51pt image: a 4pt white stroke on the content's
    /// exact bounds reads as a ring around a picture, and a 1.22x pop is free
    /// because the cell is fixed-size with space around it. Applied to a text
    /// chip both are wrong — the stroke lands directly on the glyphs instead
    /// of around them, and scaling a chip inside a width-packed row pushes its
    /// neighbours out of the line it was measured to fit. This keeps the same
    /// visual language (white outline marking the selected member of an
    /// accent-filled row) at a weight text can survive: thinner stroke, no
    /// scale, and the chip supplies its own padding so the outline has
    /// somewhere to sit.
    case textCell
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

                        .shadow(color: Color.accentColor.opacity(isSelected ? 0.22 : 0),
                                radius: isSelected ? 4 : 0, x: 0, y: isSelected ? 1.5 : 0)
                }
                .padding(.horizontal, inset)
                .scaleEffect(isSelected ? SelectionHighlightStyle.scale : 1.0)
                .animation(SelectionHighlightStyle.spring, value: isSelected)
        case .cell:
            // Deliberately NO matchedGeometryEffect here. The cells this is
            // applied to live inside an HStack carrying
            // `.transaction { $0.animation = nil }` (ImageRunRow), and a
            // matched-geometry frame change animates with the *ambient*
            // transaction — which that modifier had just set to nil. The
            // result was the highlight box teleporting to the next image
            // while the `.animation(_:value:)` below still sprang its scale
            // and opacity over 0.35s: two halves of one effect on different
            // clocks, which is what read as jerky when stepping through a
            // row of images. Each cell now animates its own highlight in
            // and out, which `.animation(_:value:)` drives correctly even
            // under a nil ambient transaction.
            //
            // The stroke is also a solid colour rather than
            // `.ultraThinMaterial`: a material is a live backdrop blur that
            // has to be re-sampled and re-composited every frame, and two
            // of them animated simultaneously (outgoing shrinking, incoming
            // growing) on every keystroke.
            content
                .overlay {
                    RoundedRectangle(cornerRadius: SelectionHighlightStyle.cellCornerRadius, style: .continuous)
                        .stroke(Color.white.opacity(0.85), lineWidth: SelectionHighlightStyle.cellBorderWidth)
                        .opacity(isSelected ? 1 : 0)
                        .shadow(color: Color.black.opacity(isSelected ? 0.3 : 0),
                                radius: isSelected ? 6 : 0, x: 0, y: isSelected ? 2 : 0)
                }

                .scaleEffect(isSelected ? SelectionHighlightStyle.cellScale : 1.0)
                .animation(SelectionHighlightStyle.spring, value: isSelected)
        case .textCell:
            // Identical to `.cell` in every animated property — same spring,
            // same scale, same shadow — and differs ONLY in stroke width.
            // A selected member of a packed row has to travel and lift the
            // same way whether that row holds thumbnails or text; anything
            // else reads as two different selection systems in one list.
            //
            // The scale is emphatically not a layout problem: `scaleEffect`
            // is a render transform, so the chip's frame — which is what
            // the row was width-packed against — does not change, and its
            // neighbours do not move.
            //
            // No matchedGeometryEffect, for exactly the reason `.cell`
            // documents above: these live inside an HStack that nils the
            // ambient transaction, so a matched frame change would jump
            // while the spring below was still running.
            content
                .overlay {
                    RoundedRectangle(cornerRadius: SelectionHighlightStyle.cellCornerRadius, style: .continuous)
                        .stroke(Color.white.opacity(0.85),
                                lineWidth: SelectionHighlightStyle.textCellBorderWidth)
                        .opacity(isSelected ? 1 : 0)
                        .shadow(color: Color.black.opacity(isSelected ? 0.3 : 0),
                                radius: isSelected ? 6 : 0, x: 0, y: isSelected ? 2 : 0)
                }
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
