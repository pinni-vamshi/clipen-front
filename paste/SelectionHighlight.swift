import SwiftUI

enum SelectionHighlightStyle {
    static let scale: CGFloat = 1.12
    static let cornerRadius: CGFloat = 8
    static let spring = Animation.spring(response: 0.35, dampingFraction: 0.75)
}

struct SelectionHighlight: ViewModifier {
    let isSelected: Bool
    let namespace: Namespace.ID

    let inset: CGFloat

    func body(content: Content) -> some View {
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
    }
}

extension View {

    func selectionHighlight(isSelected: Bool, namespace: Namespace.ID,
                             inset: CGFloat) -> some View {
        modifier(SelectionHighlight(isSelected: isSelected, namespace: namespace,
                                     inset: inset))
    }
}
