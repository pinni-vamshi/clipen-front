import SwiftUI

enum SelectionHighlightStyle {
    static let scale: CGFloat = 1.12
    static let cellScale: CGFloat = 1.22
    static let cornerRadius: CGFloat = 8
    static let cellCornerRadius: CGFloat = 6
    static let cellBorderWidth: CGFloat = 4.0
    static let spring = Animation.spring(response: 0.35, dampingFraction: 0.75)
}

enum SelectionHighlightAppearance {
    case row
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
        case .cell:
            content
                .overlay {
                    RoundedRectangle(cornerRadius: SelectionHighlightStyle.cellCornerRadius, style: .continuous)
                        .stroke(Color.accentColor, lineWidth: SelectionHighlightStyle.cellBorderWidth)
                        .opacity(isSelected ? 1 : 0)
                        .matchedGeometryEffect(id: "selectionBox", in: namespace, isSource: isSelected)
                        .shadow(color: Color.accentColor.opacity(isSelected ? 0.3 : 0),
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
