import AppKit
import SwiftUI

struct AttributedTextPreview: NSViewRepresentable {
    let attributedString: NSAttributedString

    final class Coordinator { var shown: NSAttributedString? }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.importsGraphics = true
        textView.allowsUndo = false
        textView.textStorage?.setAttributedString(attributedString)
        context.coordinator.shown = attributedString
        return scrollView
    }

    // Compared by identity, not by `.string`: the colour-adjusted copy for
    // the other appearance has the same characters, so a string compare
    // kept the old colours after a Light/Dark switch. AdjustedAttrCache
    // hands back the same object for the same source and appearance, so
    // identity only changes when the content really did.
    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if context.coordinator.shown !== attributedString {
            textView.textStorage?.setAttributedString(attributedString)
            context.coordinator.shown = attributedString
        }
    }
}
