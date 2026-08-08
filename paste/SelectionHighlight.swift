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
    /// Constant for every row, selected or not — deliberately NOT a
    /// selected/resting pair that animates between two values.
    ///
    /// Animating the horizontal inset changes the row's available width on
    /// every frame of the spring, which re-lays-out its content: the text
    /// re-wraps and visibly slides relative to the fixed rail/divider on
    /// its left, so the body appears to detach and drift away from the
    /// divider as the selection arrives. (The content's own
    /// `.transaction { $0.animation = nil }` suppresses its animation but
    /// not the relayout, which is what made it read as a jerky snap rather
    /// than a glide.) It also costs a full text layout pass per frame,
    /// compounding any slowness from a large item.
    ///
    /// With the inset fixed, `scaleEffect` below is the ONLY thing that
    /// changes — and scale is a pure transform, applied to the already
    /// laid-out row. Nothing reflows, so the content stays locked to the
    /// divider and the whole row grows as one rigid unit, which is exactly
    /// how tvOS's focus lift behaves.
    let inset: CGFloat

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
                    .shadow(color: Color.accentColor.opacity(isSelected ? 0.22 : 0),
                            radius: isSelected ? 4 : 0, x: 0, y: isSelected ? 1.5 : 0)
            }
            .padding(.horizontal, inset)
            // Uniform scale — grows both width and height together so the
            // pop reads as a lift, not a one-directional stretch. The only
            // animating property here, by design (see `inset` above).
            .scaleEffect(isSelected ? SelectionHighlightStyle.scale : 1.0)
            .animation(SelectionHighlightStyle.spring, value: isSelected)
    }
}

extension View {
    /// Applies the shared selection "lift" — see `SelectionHighlight`.
    ///
    /// `inset` is the only per-panel knob: how far every row sits in from
    /// its container's edges. Size it so the SCALED row still fits that
    /// panel's fixed width — i.e. `(width - 2*inset) * scale <= width`.
    func selectionHighlight(isSelected: Bool, namespace: Namespace.ID,
                             inset: CGFloat) -> some View {
        modifier(SelectionHighlight(isSelected: isSelected, namespace: namespace,
                                     inset: inset))
    }
}
