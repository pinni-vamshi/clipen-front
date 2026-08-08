import SwiftUI

/// Shared "focus lift" used by the main popup's `PopoverRow`, the
/// Transform panel's `TransformRow`, and the Share panel's `ShareRow` — one
/// definition so all three panels move identically and only need tuning in
/// one place.
///
/// Modeled on tvOS's focus engine: a single shared indicator travels
/// between items via `matchedGeometryEffect`, and the SAME spring drives
/// both that travel and the indicator's own scale/elevation, in both
/// directions (becoming selected AND falling back to resting). tvOS
/// doesn't swap animation curves by direction, and mixing curves (a spring
/// one way, an ease the other, or a different curve for position vs scale)
/// is exactly what made fast, repeated selection changes look like they
/// were resetting instead of gliding — SwiftUI's spring animations are
/// interruptible by default (a new target blends in from the current
/// position/velocity rather than snapping back to start), but only stay
/// smooth under that interruption if every consumer of the same value uses
/// the same curve.
enum SelectionHighlightStyle {
    static let scale: CGFloat = 1.12
    static let cornerRadius: CGFloat = 8
    static let spring = Animation.spring(response: 0.35, dampingFraction: 0.75)
}

struct SelectionHighlight: ViewModifier {
    let isSelected: Bool
    let namespace: Namespace.ID
    let selectedInset: CGFloat
    let restingInset: CGFloat

    func body(content: Content) -> some View {
        content
            // Always present (never conditionally inserted) so exactly one
            // row's copy has `isSource: true` at any instant — the rest are
            // `false` placeholders SwiftUI interpolates the travel between.
            // Conditionally inserting/removing this view used to trigger
            // SwiftUI's "Multiple inserted views ... have `isSource: true`"
            // fault on selection changes.
            .background {
                RoundedRectangle(cornerRadius: SelectionHighlightStyle.cornerRadius, style: .continuous)
                    .fill(Color.accentColor)
                    .opacity(isSelected ? 1 : 0)
                    .matchedGeometryEffect(id: "selectionBox", in: namespace, isSource: isSelected)
                    // The "elevation" half of the lift — a soft shadow that
                    // only appears while selected, riding the same spring
                    // as the scale below so the lift and the size change
                    // read as one motion.
                    .shadow(color: Color.accentColor.opacity(isSelected ? 0.45 : 0),
                            radius: isSelected ? 8 : 0, x: 0, y: isSelected ? 3 : 0)
            }
            .padding(.horizontal, isSelected ? selectedInset : restingInset)
            // Uniform scale — grows both width and height together so the
            // pop reads as a lift, not a one-directional stretch.
            .scaleEffect(isSelected ? SelectionHighlightStyle.scale : 1.0)
            .animation(SelectionHighlightStyle.spring, value: isSelected)
    }
}

extension View {
    /// Applies the shared selection "lift" — see `SelectionHighlight`.
    /// `selectedInset`/`restingInset` are the only per-panel knobs: how far
    /// each row insets from its container at rest vs. selected, sized so
    /// the popped box still fits inside that panel's own fixed width.
    func selectionHighlight(isSelected: Bool, namespace: Namespace.ID,
                             selectedInset: CGFloat, restingInset: CGFloat) -> some View {
        modifier(SelectionHighlight(isSelected: isSelected, namespace: namespace,
                                     selectedInset: selectedInset, restingInset: restingInset))
    }
}
