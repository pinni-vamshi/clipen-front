import AppKit
import InputMethodKit

/// Transparent IMK input controller that tracks the caret position via the
/// NSTextInputClient protocol.  When the user adds "Clipen" to
/// System Settings › Keyboard › Input Sources, every text field in every app
/// calls firstRect(forCharacterRange:actualRange:) on our controller, giving
/// us the exact blinker rect.  We store it and pass all events through.
@objc(ClipboardInputController)
final class ClipboardInputController: IMKInputController {

    // IMK calls handle() for every raw key event received by the focused client.
    // Return false = "not handled" → event continues to the app normally.
    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        updateCaretRect(from: sender)
        return false
    }

    // inputText() is called for printable characters.
    override func inputText(_ string: String!, client sender: Any!) -> Bool {
        updateCaretRect(from: sender)
        return false
    }

    private func updateCaretRect(from sender: Any!) {
        guard let client = sender as? IMKTextInput else { return }
        let selectedRange = client.selectedRange()
        guard selectedRange.location != NSNotFound else { return }
        var actualRange = NSRange()
        // The client reports the rect of the insertion point in screen
        // coordinates (AppKit bottom-left origin on the primary display).
        let rect = client.firstRect(forCharacterRange: selectedRange, actualRange: &actualRange)
        guard rect != .zero, rect.origin.x.isFinite, rect.origin.y.isFinite else { return }
        DispatchQueue.main.async {
            ClipboardManager.shared.imkCaretRect = rect
            ClipboardManager.shared.imkCaretRectTimestamp = Date()
        }
    }
}
