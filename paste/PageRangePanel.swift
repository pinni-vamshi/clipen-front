import AppKit
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

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            queryRow
            Divider()
            grid
            Divider()
            footer
        }
    }

    // MARK: Header
    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text.below.ecg")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text("Pick pages to paste")
                    .font(.system(size: 12, weight: .semibold))
                Text("\(manager.pageRangePageCount) page\(manager.pageRangePageCount == 1 ? "" : "s") total")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: Range input (visual only — keystrokes routed via CGEventTap)
    private var queryRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "textformat.123")
                .font(.system(size: 11))
                .foregroundColor(.accentColor)
            Group {
                if manager.pageRangeQuery.isEmpty {
                    Text("Type e.g. 1-3, 5, 7-9")
                        .foregroundColor(.secondary.opacity(0.55))
                } else {
                    Text(manager.pageRangeQuery + "▌")
                        .foregroundColor(.primary)
                }
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
        .frame(maxHeight: 240)
    }

    // MARK: Footer
    private var footer: some View {
        let count = manager.pageRangeEffectiveSelection.count
        return VStack(alignment: .leading, spacing: 4) {
            Text(count == 0 ? "No pages selected"
                            : (count == 1 ? "1 page selected" : "\(count) pages selected"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(count == 0 ? .secondary : .accentColor)
            HStack(spacing: 10) {
                hintChip(key: "↵", label: "Paste", enabled: count > 0)
                hintChip(key: "␣", label: "Preview", enabled: count > 0)
                hintChip(key: "⎋", label: "Cancel", enabled: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func hintChip(key: String, label: String, enabled: Bool) -> some View {
        HStack(spacing: 3) {
            Text(key)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Color.primary.opacity(enabled ? 0.10 : 0.05),
                            in: RoundedRectangle(cornerRadius: 3))
            Text(label)
                .font(.system(size: 9, weight: .medium))
        }
        .foregroundColor(enabled ? .secondary : .secondary.opacity(0.4))
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
