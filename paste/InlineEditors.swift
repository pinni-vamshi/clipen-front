import AppKit
import AVKit
import Highlightr
import ModelIO
import NaturalLanguage
import Quartz
import SceneKit
import SceneKit.ModelIO
import SwiftUI
import WebKit
@preconcurrency import PDFKit


// ============================================================================
// Inline editor — E on the popup opens this. Positioned like ItemPreviewView
// (side of the popup, anchored to the selected row), NSTextView-backed, with
// Enter to save, Shift+Enter for a literal newline, Esc to cancel.
// ============================================================================

struct InlineRichEditView: View {
    let initialAttributedString: NSAttributedString
    let onCommit: (NSAttributedString) -> Void
    let onCommitAndPaste: (NSAttributedString) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.accentColor)
                Text("Edit")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                HStack(spacing: 12) {
                    Text("↩ Save").font(.system(size: 9)).foregroundColor(.secondary)
                    Text("⇧↩ Newline").font(.system(size: 9)).foregroundColor(.secondary)
                    Text("↩↩ Save & Paste").font(.system(size: 9)).foregroundColor(.secondary)
                    Text("Esc Cancel").font(.system(size: 9)).foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            RichEditableTextArea(
                attributedString: initialAttributedString,
                onCommit: onCommit,
                onCommitAndPaste: onCommitAndPaste,
                onCancel: onCancel
            )
            .padding(14)
        }
    }
}

private struct RichEditableTextArea: NSViewRepresentable {
    let attributedString: NSAttributedString
    let onCommit: (NSAttributedString) -> Void
    let onCommitAndPaste: (NSAttributedString) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.inlineEditScrollableTextView()
        guard let tv = scroll.documentView as? InlineEditTextView else { return scroll }
        tv.isRichText = true
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.textContainerInset = NSSize(width: 4, height: 6)
        tv.usesFontPanel = false
        tv.usesRuler = false
        tv.textStorage?.setAttributedString(attributedString)

        tv.commitHandler = { [weak tv] in
            guard let tv, let storage = tv.textStorage else { return }
            onCommit(NSAttributedString(attributedString: storage))
        }
        tv.commitAndPasteHandler = { [weak tv] in
            guard let tv, let storage = tv.textStorage else { return }
            onCommitAndPaste(NSAttributedString(attributedString: storage))
        }
        tv.cancelHandler = onCancel

        DispatchQueue.main.async {
            if let win = tv.window { win.makeFirstResponder(tv) }
            let end = tv.textStorage?.length ?? 0
            tv.setSelectedRange(NSRange(location: end, length: 0))
        }
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let tv = nsView.documentView as? InlineEditTextView else { return }
        tv.commitHandler = { [weak tv] in
            guard let tv, let storage = tv.textStorage else { return }
            onCommit(NSAttributedString(attributedString: storage))
        }
        tv.commitAndPasteHandler = { [weak tv] in
            guard let tv, let storage = tv.textStorage else { return }
            onCommitAndPaste(NSAttributedString(attributedString: storage))
        }
        tv.cancelHandler = onCancel
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: ()) {
        (nsView.documentView as? InlineEditTextView)?.commitHandler = nil
        (nsView.documentView as? InlineEditTextView)?.commitAndPasteHandler = nil
        (nsView.documentView as? InlineEditTextView)?.cancelHandler = nil
    }
}

private struct EditorKeyMonitor: NSViewRepresentable {
    let onCommit: () -> Void
    let onCommitAndPaste: () -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onCommit = onCommit
        context.coordinator.onCommitAndPaste = onCommitAndPaste
        context.coordinator.onCancel = onCancel
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var onCommit: (() -> Void)?
        var onCommitAndPaste: (() -> Void)?
        var onCancel: (() -> Void)?
        private var monitor: Any?
        private var pendingCommit: DispatchWorkItem?
        private static let doubleEnterWindow: TimeInterval = 0.35

        init() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                if event.keyCode == 36 || event.keyCode == 76 {
                    if event.modifierFlags.contains(.shift) || event.modifierFlags.contains(.option) {
                        return event
                    }
                    if let pending = pendingCommit {
                        pending.cancel()
                        pendingCommit = nil
                        onCommitAndPaste?()
                        return nil
                    }
                    let work = DispatchWorkItem { [weak self] in
                        self?.pendingCommit = nil
                        self?.onCommit?()
                    }
                    pendingCommit = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + Self.doubleEnterWindow, execute: work)
                    return nil
                }
                if event.keyCode == 53 {
                    pendingCommit?.cancel()
                    pendingCommit = nil
                    onCancel?()
                    return nil
                }
                return event
            }
        }

        deinit {
            pendingCommit?.cancel()
            if let m = monitor { NSEvent.removeMonitor(m) }
        }
    }
}

struct InlineMixedEditView: View {
    let initialSegments: [ContentSegment]
    let onCommit: ([ContentSegment]) -> Void
    let onCommitAndPaste: ([ContentSegment]) -> Void
    let onCancel: () -> Void

    @State private var segments: [ContentSegment] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.accentColor)
                Text("Edit")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                HStack(spacing: 12) {
                    Text("↩ Save").font(.system(size: 9)).foregroundColor(.secondary)
                    Text("⇧↩ Newline").font(.system(size: 9)).foregroundColor(.secondary)
                    Text("↩↩ Save & Paste").font(.system(size: 9)).foregroundColor(.secondary)
                    Text("Esc Cancel").font(.system(size: 9)).foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            ScrollView {
                VStack(spacing: 12) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { idx, seg in
                        switch seg {
                        case .text:
                            MixedTextSegment(text: Binding(
                                get: { if case .text(let t) = segments[idx] { return t }; return "" },
                                set: { segments[idx] = .text($0) }
                            ))
                        case .table:
                            MixedTableSegment(rows: Binding(
                                get: { if case .table(let r) = segments[idx] { return r }; return [] },
                                set: { segments[idx] = .table($0) }
                            ))
                        }
                    }
                }
                .padding(14)
            }
        }
        .onAppear { segments = initialSegments }
        .background(EditorKeyMonitor(
            onCommit: { onCommit(segments) },
            onCommitAndPaste: { onCommitAndPaste(segments) },
            onCancel: onCancel
        ))
    }
}

private struct MixedTextSegment: View {
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Text").font(.system(size: 9, weight: .medium)).foregroundColor(.secondary)
            PlainTextSegmentEditor(text: $text)
                .frame(minHeight: 44, maxHeight: 220)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.15), lineWidth: 1))
        }
    }
}

private struct MixedTableSegment: View {
    @Binding var rows: [[String]]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Table").font(.system(size: 9, weight: .medium)).foregroundColor(.secondary)
            EditableTableGrid(rows: $rows)
        }
    }
}

private struct PlainTextSegmentEditor: NSViewRepresentable {
    @Binding var text: String

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PlainTextSegmentEditor
        init(_ p: PlainTextSegmentEditor) { parent = p }
        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false

        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true

        let layoutManager = NSLayoutManager()
        layoutManager.addTextContainer(container)

        let storage = NSTextStorage()
        storage.addLayoutManager(layoutManager)

        let tv = NSTextView(frame: .zero, textContainer: container)
        tv.isRichText = false
        tv.allowsUndo = true
        tv.font = .systemFont(ofSize: 11)
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.textContainerInset = NSSize(width: 4, height: 6)
        tv.drawsBackground = false
        tv.delegate = context.coordinator
        tv.string = text

        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]

        scroll.documentView = tv
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let tv = nsView.documentView as? NSTextView else { return }
        if tv.string != text { tv.string = text }
    }
}

struct InlineTableEditView: View {
    let initialRows: [[String]]
    let onCommit: ([[String]]) -> Void
    let onCommitAndPaste: ([[String]]) -> Void
    let onCancel: () -> Void

    @State private var rows: [[String]] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "tablecells")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.accentColor)
                Text("Edit Table")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                HStack(spacing: 12) {
                    Text("↩ Save").font(.system(size: 9)).foregroundColor(.secondary)
                    Text("↩↩ Save & Paste").font(.system(size: 9)).foregroundColor(.secondary)
                    Text("Esc Cancel").font(.system(size: 9)).foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            EditableTableGrid(rows: $rows)
                .padding(14)
        }
        .onAppear { rows = initialRows }
        .background(EditorKeyMonitor(
            onCommit: { onCommit(rows) },
            onCommitAndPaste: { onCommitAndPaste(rows) },
            onCancel: onCancel
        ))
    }
}

/// A standalone, centered window that teaches one gesture at a time.
/// Deliberately NOT built on the shared popover/`present(...)` machinery every
/// other panel in this file uses — those are all anchored to and torn down
/// with the ring popup, which is exactly the coupling that made the old
/// nudge design unusable (see ClipboardManager+Nudges.swift): a fluent user's
/// popup session could end, and take the lesson down with it, before there
/// was ever a real chance to read it. This panel owns its own NSPanel,
/// floats above every space, and only closes via its own "Learned"/"Later"
/// buttons or automatic natural-use detection — it does not know or care
/// whether the ring popup is open.

struct InlineEditView: View {
    let item: ClipboardItem
    let initialText: String
    let onCommit: (String) -> Void
    let onCommitAndPaste: (String) -> Void
    let onCancel: () -> Void

    @State private var draft: String = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.accentColor)
                Text("Edit")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                HStack(spacing: 12) {
                    Text("↩ Save").font(.system(size: 9)).foregroundColor(.secondary)
                    Text("⇧↩ Newline").font(.system(size: 9)).foregroundColor(.secondary)
                    Text("↩↩ Save & Paste").font(.system(size: 9)).foregroundColor(.secondary)
                    Text("Esc Cancel").font(.system(size: 9)).foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            EditableTextArea(text: $draft,
                             onCommit: { onCommit(draft) },
                             onCommitAndPaste: { onCommitAndPaste(draft) },
                             onCancel: onCancel)
                .padding(14)
        }
        .onAppear { draft = initialText }
    }
}

private struct EditableTextArea: NSViewRepresentable {
    @Binding var text: String
    let onCommit: () -> Void
    let onCommitAndPaste: () -> Void
    let onCancel: () -> Void

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: EditableTextArea
        init(_ p: EditableTextArea) { parent = p }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.inlineEditScrollableTextView()
        guard let tv = scroll.documentView as? InlineEditTextView else { return scroll }
        tv.delegate = context.coordinator
        tv.string = text
        tv.font = .systemFont(ofSize: 13)
        tv.isRichText = false
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.textContainerInset = NSSize(width: 4, height: 6)
        tv.commitHandler = onCommit
        tv.commitAndPasteHandler = onCommitAndPaste
        tv.cancelHandler = onCancel

        DispatchQueue.main.async {
            if let win = tv.window { win.makeFirstResponder(tv) }
            // Cursor placed at the end, not a select-all — pressing E should
            // drop the user straight into typing/appending, with the blinking
            // caret already live, no extra click needed to start writing.
            let end = (tv.string as NSString).length
            tv.setSelectedRange(NSRange(location: end, length: 0))
        }
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let tv = nsView.documentView as? InlineEditTextView else { return }
        if tv.string != text { tv.string = text }
        tv.commitHandler = onCommit
        tv.commitAndPasteHandler = onCommitAndPaste
        tv.cancelHandler = onCancel
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        (nsView.documentView as? InlineEditTextView)?.commitHandler = nil
        (nsView.documentView as? InlineEditTextView)?.commitAndPasteHandler = nil
        (nsView.documentView as? InlineEditTextView)?.cancelHandler = nil
    }
}

private final class InlineEditTextView: NSTextView {
    var commitHandler: (() -> Void)?
    var commitAndPasteHandler: (() -> Void)?
    var cancelHandler: (() -> Void)?

    /// A bare Return doesn't commit right away — it waits this long for a
    /// second Return. If one lands in time, that's "Save & Paste"; if not,
    /// the pending commit fires on its own as a plain Save. This is the only
    /// way to detect a double-tap at all, since a naive immediate-commit
    /// would tear the editor down on the first Return and leave nothing
    /// alive to catch the second.
    private static let doubleEnterWindow: TimeInterval = 0.35
    private var pendingCommit: DispatchWorkItem?

    // NSTextView's default class isn't overridable through
    // scrollableTextView() — but the constructor stores an NSTextView, which
    // we replace with a real InlineEditTextView subclass instance via a swap
    // in scrollableTextView (see the extension below).

    override func keyDown(with event: NSEvent) {
        // Return alone commits (or commits+pastes on a fast double-tap);
        // Shift/Option+Return inserts a literal newline.
        if event.keyCode == 36 || event.keyCode == 76 {
            if event.modifierFlags.contains(.shift) || event.modifierFlags.contains(.option) {
                super.keyDown(with: event)
                return
            }
            if let pending = pendingCommit {
                pending.cancel()
                pendingCommit = nil
                commitAndPasteHandler?()
                return
            }
            let work = DispatchWorkItem { [weak self] in
                self?.pendingCommit = nil
                self?.commitHandler?()
            }
            pendingCommit = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.doubleEnterWindow, execute: work)
            return
        }
        // Escape cancels — NSTextView's default cancelOperation would only
        // dismiss the completion window if any, so we override outright.
        if event.keyCode == 53 {
            pendingCommit?.cancel()
            pendingCommit = nil
            cancelHandler?()
            return
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        pendingCommit?.cancel()
        pendingCommit = nil
        cancelHandler?()
    }
}

// Route NSTextView.scrollableTextView() through our subclass so the returned
// scroll view already contains an InlineEditTextView document view.
private extension NSTextView {
    static func inlineEditScrollableTextView() -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false

        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.heightTracksTextView = false

        let layoutManager = NSLayoutManager()
        let storage = NSTextStorage()
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)

        let tv = InlineEditTextView(frame: .zero, textContainer: container)
        tv.autoresizingMask = [.width]
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                            height: CGFloat.greatestFiniteMagnitude)
        tv.drawsBackground = false
        scroll.documentView = tv
        return scroll
    }
}
