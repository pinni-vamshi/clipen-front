import AppKit
import SwiftUI
@preconcurrency import PDFKit

// MARK: - Activating panel for picking PDF pages to paste

/// Interactive sub-panel that opens when the user picks the "Paste Specific
/// Pages" PDF transform.  Unlike the main popup (.nonactivatingPanel), this
/// panel IS activating so a real SwiftUI TextField can receive keystrokes
/// naturally — exactly the same pattern as SearchOverlayWindow.  On commit
/// it writes the extracted text to NSPasteboard, hides itself, restores
/// focus to the original front app, then fires a simulated ⌘V so the app
/// receives the paste.
final class PageRangePanel: NSPanel {
    private var hostingView: NSHostingView<PageRangePickerView>?
    private var returnApp: NSRunningApplication?

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless],     // activating panel — needs key for TextField
            backing:   .buffered,
            defer:     false
        )
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false                 // SwiftUI draws the shadow
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    // NSPanels with .borderless need this to become key window.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func show(pdf: PDFDocument, sourceApp: NSRunningApplication?) {
        returnApp = sourceApp

        let screen = NSScreen.main?.visibleFrame
                  ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let w: CGFloat = 480
        let h: CGFloat = 460
        let x = screen.midX - w / 2
        let y = screen.midY - h / 2 + 60

        let view = PageRangePickerView(
            pdf: pdf,
            pageCount: pdf.pageCount,
            onCommit: { [weak self] pages in self?.commit(pages: pages, pdf: pdf) },
            onCancel: { [weak self] in self?.cancel() }
        )

        if let hv = hostingView {
            hv.rootView = view
        } else {
            let hv = NSHostingView(rootView: view)
            contentView = hv
            hostingView = hv
        }

        setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hide() { orderOut(nil) }

    private func cancel() {
        hide()
        returnApp?.activate(options: .activateIgnoringOtherApps)
        returnApp = nil
    }

    /// Extract text from the chosen pages (in ascending order), write to the
    /// pasteboard, restore the original app's focus, then post a ⌘V so the
    /// app receives the paste — same handshake as the search-overlay commit.
    private func commit(pages: [Int], pdf: PDFDocument) {
        guard !pages.isEmpty else { cancel(); return }
        let chunks: [String] = pages.compactMap { idx in
            guard idx >= 0, idx < pdf.pageCount,
                  let str = pdf.page(at: idx)?.string else { return nil }
            let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        let combined = chunks.joined(separator: "\n\n")
        guard !combined.isEmpty else { cancel(); return }

        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(combined, forType: .string)
        ClipboardManager.shared.markPasteboardWriteAsOwn()

        hide()
        let app = returnApp
        returnApp = nil
        app?.activate(options: .activateIgnoringOtherApps)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            ClipboardManager.shared.simulateCommandV()
        }
    }
}

// MARK: - SwiftUI page-picker view

struct PageRangePickerView: View {
    let pdf: PDFDocument
    let pageCount: Int
    let onCommit: ([Int]) -> Void   // 0-indexed page indices, sorted ascending
    let onCancel: () -> Void

    @State private var rangeText: String = ""
    @State private var manuallyToggled: Set<Int> = []   // pages clicked individually (0-indexed)
    @FocusState private var rangeFocused: Bool

    /// Pages selected by parsing `rangeText` (1-indexed input → 0-indexed set).
    private var rangeSelection: Set<Int> {
        Self.parseRange(rangeText, maxPage: pageCount)
    }

    /// Final selection = union of typed range AND manually clicked pages.
    /// Lets the user type "1-3" then click page 7 to add it, all in one go.
    private var effectiveSelection: Set<Int> {
        rangeSelection.union(manuallyToggled)
    }

    private var sortedSelection: [Int] {
        effectiveSelection.sorted()
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── Header ──
            HStack(spacing: 8) {
                Image(systemName: "doc.text.below.ecg")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Pick pages to paste")
                        .font(.system(size: 13, weight: .semibold))
                    Text("\(pageCount) page\(pageCount == 1 ? "" : "s") total")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Text("Esc")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary.opacity(0.7))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            // ── Range input ──
            HStack(spacing: 10) {
                Image(systemName: "textformat.123")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                TextField("e.g. 1-3, 5, 7-9", text: $rangeText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($rangeFocused)
                    .onSubmit { commitIfPossible() }
                if !rangeText.isEmpty {
                    Button { rangeText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.primary.opacity(0.03))

            Divider()

            // ── Page grid — every page as a clickable button ──
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 8), spacing: 6) {
                    ForEach(0..<pageCount, id: \.self) { idx in
                        let isOn = effectiveSelection.contains(idx)
                        Button {
                            // Toggle manual selection.  If the page was only
                            // in the typed range (not manually clicked), one
                            // click should REMOVE it — so we add the inverse
                            // marker to manuallyToggled.  Keep it simple:
                            // toggle the manual set; the union takes care of
                            // showing whatever ends up selected.
                            if manuallyToggled.contains(idx) {
                                manuallyToggled.remove(idx)
                            } else {
                                manuallyToggled.insert(idx)
                            }
                        } label: {
                            Text("\(idx + 1)")
                                .font(.system(size: 12, weight: isOn ? .semibold : .regular, design: .monospaced))
                                .foregroundColor(isOn ? .white : .primary)
                                .frame(maxWidth: .infinity, minHeight: 30)
                                .background(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(isOn ? Color.accentColor : Color.primary.opacity(0.06))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .stroke(isOn ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(12)
            }

            Divider()

            // ── Footer with commit button ──
            HStack(spacing: 12) {
                Text(footerLabel)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(effectiveSelection.isEmpty ? .secondary : .primary)
                Spacer()
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.regular)
                Button {
                    commitIfPossible()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "return")
                            .font(.system(size: 10, weight: .bold))
                        Text("Paste")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(effectiveSelection.isEmpty ? Color.accentColor.opacity(0.4) : Color.accentColor)
                    )
                }
                .buttonStyle(.plain)
                .disabled(effectiveSelection.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 28, x: 0, y: 14)
        .onAppear { rangeFocused = true }
    }

    private var footerLabel: String {
        let n = effectiveSelection.count
        if n == 0 { return "No pages selected" }
        if n == 1 { return "1 page selected" }
        return "\(n) pages selected"
    }

    private func commitIfPossible() {
        let sel = sortedSelection
        guard !sel.isEmpty else { return }
        onCommit(sel)
    }

    // MARK: Range parsing

    /// Parse strings like "1-3, 5, 7-9" → set of 0-indexed page numbers.
    /// Ignores out-of-bounds and malformed tokens silently — better UX than
    /// a parse-error toast since the grid shows the result live.
    static func parseRange(_ text: String, maxPage: Int) -> Set<Int> {
        guard !text.isEmpty, maxPage > 0 else { return [] }
        var result: Set<Int> = []
        let parts = text.split(separator: ",")
        for part in parts {
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
