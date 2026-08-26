import AppKit
import SwiftUI

struct AttributedTextPreview: NSViewRepresentable {
    let attributedString: NSAttributedString

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.importsGraphics = true
        textView.allowsUndo = false
        textView.textStorage?.setAttributedString(attributedString)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.textStorage?.string != attributedString.string {
            textView.textStorage?.setAttributedString(attributedString)
        }
    }
}
