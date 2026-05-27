import AppKit
import Combine
import SwiftUI
@preconcurrency import PDFKit

// MARK: - Inline page-picker view (rendered inside TransformPanel)

/// Replaces the tool list inside the existing TransformPanel when the user
/// has picked the "Paste Specific Pages" PDF transform.  Reads its state
/// from ClipboardManager so all input — typed digits/commas/dashes, manual
/// page clicks, Space-preview, Enter-commit, Esc-cancel — can be driven
/// either by mouse (clicks work in non-activating panels) or by the
/// CGEventTap (which routes keystrokes since the panel can't take focus).
struct InlinePagePicker: View {
    @ObservedObject private var manager = ClipboardManager.shared

    // No header here — the outer TransformView header already announces
    // "Paste Specific Pages" with the page count.  Keeping a duplicate
    // header would make the picker look like a separate panel.  This view
    // is purely the picker's CONTENT: query row, page grid, selection count.
    var body: some View {
        VStack(spacing: 0) {
            queryRow
            Divider()
            grid
            Divider()
            selectionCountRow
        }
    }

    // MARK: Range input (visual only — keystrokes routed via CGEventTap)
    private var queryRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "textformat.123")
                .font(.system(size: 11))
                .foregroundColor(.accentColor)
            HStack(spacing: 0) {
                if manager.pageRangeQuery.isEmpty {
                    BlinkingCursor()
                        .foregroundColor(.accentColor)
                    Text("Type e.g. 1-3, 5, 7-9")
                        .foregroundColor(.secondary.opacity(0.55))
                } else {
                    Text(manager.pageRangeQuery)
                        .foregroundColor(.primary)
                    BlinkingCursor()
                        .foregroundColor(.accentColor)
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 12, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
            .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.accentColor.opacity(0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.accentColor.opacity(0.4), lineWidth: 1)
        )
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // MARK: Page grid — clickable buttons (mouse works in non-activating panel)
    // Fills available space (no fixed maxHeight) so header / query / footer
    // never get clipped when the panel is shorter than the picker's natural
    // content height.  The grid itself scrolls if there are many pages.
    private var grid: some View {
        let pageCount = manager.pageRangePageCount
        let effective = manager.pageRangeEffectiveSelection
        return ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 6), spacing: 5) {
                ForEach(0..<pageCount, id: \.self) { idx in
                    let isOn = effective.contains(idx)
                    Button {
                        manager.togglePageRangeManualPage(idx)
                    } label: {
                        Text("\(idx + 1)")
                            .font(.system(size: 11, weight: isOn ? .semibold : .regular, design: .monospaced))
                            .foregroundColor(isOn ? .white : .primary)
                            .frame(maxWidth: .infinity, minHeight: 26)
                            .background(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(isOn ? Color.accentColor : Color.primary.opacity(0.06))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .stroke(isOn ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Selection count row (compact — TransformView's outer footer shows the keybinding hints)
    private var selectionCountRow: some View {
        let count = manager.pageRangeEffectiveSelection.count
        return HStack {
            Text(count == 0 ? "No pages selected"
                            : (count == 1 ? "1 page selected" : "\(count) pages selected"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(count == 0 ? .secondary : .accentColor)
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

// MARK: - Blinking cursor (shared by all non-activating-panel inputs)

/// Fake caret for places where a real `TextField` can't be used — the popup
/// search bar and the page-picker query input both live inside non-activating
/// `NSPanel`s that can't receive keyboard focus, so the system-provided
/// blinking cursor is unavailable.  This view renders a `▌` glyph that
/// toggles visibility on a 500ms cycle (matches macOS's default cursor
/// blink rate), so the user can tell at a glance "this is an active input."
struct BlinkingCursor: View {
    /// Cycle period in seconds — each tick toggles visibility, so the full
    /// on→off→on cycle is 2× this value.  0.5s gives a 1s round trip,
    /// matching NSTextField's default.
    var period: Double = 0.5

    @State private var visible: Bool = true

    var body: some View {
        Text("▌")
            .opacity(visible ? 1 : 0)
            // .common run-loop mode so the timer keeps firing during
            // scroll/tracking; otherwise the cursor freezes whenever the
            // user is interacting with another part of the panel.
            .onReceive(Timer.publish(every: period, on: .main, in: .common).autoconnect()) { _ in
                visible.toggle()
            }
            // Render the cursor at the same width whether visible or not
            // so adjacent text doesn't shift sideways every blink.
            .frame(minWidth: 6, alignment: .leading)
    }
}

// MARK: - Range parser (shared utility)

enum PageRangeParser {
    /// Parse strings like "1-3, 5, 7-9" → set of 0-indexed page numbers.
    /// Ignores out-of-bounds and malformed tokens silently — better UX than
    /// a parse-error toast, since the grid shows the live result.
    static func parse(_ text: String, maxPage: Int) -> Set<Int> {
        guard !text.isEmpty, maxPage > 0 else { return [] }
        var result: Set<Int> = []
        for part in text.split(separator: ",") {
            let token = part.trimmingCharacters(in: .whitespaces)
            if token.isEmpty { continue }
            if let dashIdx = token.firstIndex(of: "-") {
                let lhs = token[..<dashIdx].trimmingCharacters(in: .whitespaces)
                let rhs = token[token.index(after: dashIdx)...].trimmingCharacters(in: .whitespaces)
                guard let a = Int(lhs), let b = Int(rhs) else { continue }
                let lo = max(1, min(a, b))
                let hi = min(maxPage, max(a, b))
                guard lo <= hi else { continue }
                for p in lo...hi { result.insert(p - 1) }
            } else if let single = Int(token) {
                if single >= 1 && single <= maxPage { result.insert(single - 1) }
            }
        }
        return result
    }
}
