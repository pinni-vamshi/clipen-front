import AppKit
import SwiftUI
import WebKit

class QuickClipPanel: NSPanel {
    init(item: ClipboardItem, offset: CGFloat) {
        super.init(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .borderless, .resizable],
            backing: .buffered,
            defer: false
        )

        self.level = .floating
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.ignoresMouseEvents = false
        self.hidesOnDeactivate = false
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.isMovableByWindowBackground = true

        let hostingView = NSHostingView(rootView: QuickClipPanelContentView(item: item, panel: self))
        self.contentView = hostingView

        let w: CGFloat = 320
        let h: CGFloat = 340
        let screen = NSScreen.main?.visibleFrame ?? .zero
        let x = screen.midX - (w / 2) + offset
        let y = screen.midY - (h / 2) - offset

        self.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
    }

    override func close() {
        super.close()
        // Notify ClipboardManager that this panel is closed
        DispatchQueue.main.async {
            ClipboardManager.shared.quickClipPanelDidClose(self)
        }
    }
}

private struct QuickClipPanelContentView: View {
    let item: ClipboardItem
    let panel: NSPanel
    @State private var noteText: String
    @FocusState private var noteFocused: Bool
    @State private var showSimilar:      Bool = false
    @State private var similarItems:     [ClipboardItem] = []
    @State private var drawingMode:      Bool = false
    @State private var strokeColor:      Color = .red
    @State private var isEraser:         Bool = false
    @State private var annotationStrokes: [AnnotationStroke] = []
    @State private var annotationTexts:   [AnnotationTextItem] = []
    @State private var newTextInput:      String = ""

    init(item: ClipboardItem, panel: NSPanel) {
        self.item  = item
        self.panel = panel
        _noteText  = State(initialValue: item.userNote ?? "")
        let strokes: [AnnotationStroke] = {
            guard let d = item.annotationStrokesData,
                  let s = try? JSONDecoder().decode([AnnotationStroke].self, from: d) else { return [] }
            return s
        }()
        let texts: [AnnotationTextItem] = {
            guard let d = item.annotationTextsData,
                  let t = try? JSONDecoder().decode([AnnotationTextItem].self, from: d) else { return [] }
            return t
        }()
        _annotationStrokes = State(initialValue: strokes)
        _annotationTexts   = State(initialValue: texts)
    }

    private var isAnnotatable: Bool {
        switch item.content {
        case .image: return true
        case .file(let url):
            let ext = url.pathExtension.lowercased()
            return ["pdf", "png", "jpg", "jpeg", "heic", "gif", "tiff", "webp"].contains(ext)
        default: return false
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: item.iconName)
                        .font(.system(size: 11))
                        .foregroundColor(.accentColor)
                    Text(item.typeLabel)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.primary)
                }

                Spacer()

                // Copy button
                Button {
                    if let idx = ClipboardManager.shared.items.firstIndex(where: { $0.id == item.id }) {
                        ClipboardManager.shared.pasteItem(at: idx)
                    }
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Copy to clipboard")

                // Draw / annotate button (images and PDFs only)
                if isAnnotatable {
                    Button {
                        drawingMode.toggle()
                    } label: {
                        Image(systemName: drawingMode ? "pencil.circle.fill" : "pencil.circle")
                            .font(.system(size: 13))
                            .foregroundColor(drawingMode ? .accentColor : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help(drawingMode ? "Exit drawing mode" : "Draw / annotate")
                }

                Button {
                    showSimilar.toggle()
                    if showSimilar && similarItems.isEmpty {
                        similarItems = ClipboardManager.shared.similarItems(to: item)
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: showSimilar ? "square.stack.fill" : "square.stack")
                            .font(.system(size: 11))
                        if !similarItems.isEmpty && showSimilar {
                            Text("\(similarItems.count)")
                                .font(.system(size: 9, weight: .bold))
                        }
                    }
                    .foregroundColor(showSimilar ? .accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .help(showSimilar ? "Hide similar items" : "Show similar items from clipboard")

                Button(action: {
                    panel.close()
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            ZStack(alignment: .topLeading) {
                QuickClipPreview(item: item)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if drawingMode && isAnnotatable {
                    AnnotationCanvasView(
                        strokes: $annotationStrokes,
                        strokeColor: $strokeColor,
                        isEraser: $isEraser
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onChange(of: annotationStrokes) { _, newStrokes in
                        let data = try? JSONEncoder().encode(newStrokes)
                        ClipboardManager.shared.updateAnnotationStrokes(id: item.id, data: data)
                    }
                }

                // Persisted text annotation labels
                ForEach($annotationTexts) { $label in
                    DraggableAnnotationLabel(label: $label) {
                        annotationTexts.removeAll { $0.id == label.id }
                        let data = try? JSONEncoder().encode(annotationTexts)
                        ClipboardManager.shared.updateAnnotationTexts(id: item.id, data: data)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(12)
            .onDrag {
                item.makeItemProvider()
            }

            // ── Drawing toolbar ─────────────────────────────────────────────
            if drawingMode && isAnnotatable {
                Divider()
                AnnotationToolbar(
                    strokeColor: $strokeColor,
                    isEraser: $isEraser,
                    onUndo: {
                        if !annotationStrokes.isEmpty {
                            annotationStrokes.removeLast()
                            let data = try? JSONEncoder().encode(annotationStrokes)
                            ClipboardManager.shared.updateAnnotationStrokes(id: item.id, data: data)
                        }
                    },
                    onClear: {
                        annotationStrokes = []
                        ClipboardManager.shared.updateAnnotationStrokes(id: item.id, data: nil)
                    },
                    newTextInput: $newTextInput,
                    onAddText: {
                        guard !newTextInput.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                        let label = AnnotationTextItem(
                            text: newTextInput.trimmingCharacters(in: .whitespaces),
                            xFraction: 0.5,
                            yFraction: 0.15,
                            colorHex: strokeColor.hexString
                        )
                        annotationTexts.append(label)
                        newTextInput = ""
                        let data = try? JSONEncoder().encode(annotationTexts)
                        ClipboardManager.shared.updateAnnotationTexts(id: item.id, data: data)
                    }
                )
            }

            // ── Similar items ───────────────────────────────────────────────
            if showSimilar {
                Divider()
                SimilarItemsScrollView(pinned: item, similars: similarItems)
            }

            Divider()

            // ── Notes area ─────────────────────────────────────────────────
            // Free-form annotation that persists with the item across launches.
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: "pencil")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.secondary)
                    Text("Notes")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                    Spacer()
                    if !noteText.isEmpty {
                        Button {
                            noteText = ""
                            ClipboardManager.shared.updateUserNote(id: item.id, note: "")
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary.opacity(0.6))
                        }
                        .buttonStyle(.plain)
                    }
                }

                ZStack(alignment: .topLeading) {
                    if noteText.isEmpty && !noteFocused {
                        Text("Add a note\u{2026}")
                            .font(.system(size: 11))
                            .foregroundColor(Color.secondary.opacity(0.5))
                            .padding(.horizontal, 4)
                            .padding(.top, 2)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $noteText)
                        .font(.system(size: 11))
                        .frame(height: 54)
                        .scrollContentBackground(.hidden)
                        .background(Color.primary.opacity(0.05),
                                    in: RoundedRectangle(cornerRadius: 6))
                        .focused($noteFocused)
                        .onChange(of: noteText) { _, newValue in
                            ClipboardManager.shared.updateUserNote(id: item.id, note: newValue)
                        }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 10)
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.15), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.2), radius: 10, x: 0, y: 5)
    }
}

private struct QuickClipPreview: View {
    let item: ClipboardItem

    var body: some View {
        switch item.content {
        case .text(let text):
            if let url = validWebURL(text) {
                WebsitePreview(url: url)
            } else {
                textPreview(text, monospaced: true)
            }
        case .richText(let attrStr, _):
            AttributedTextPreview(attributedString: attrStr.adjustingColorsForCurrentAppearance())
        case .html(let html, let plain):
            if ClipboardManager.htmlContainsTable(html) {
                HTMLStringPreview(html: html)
            } else {
                textPreview(plain, monospaced: false)
            }
        case .rtfd(let data, let plain):
            if let attrStr = NSAttributedString(rtfd: data, documentAttributes: nil) {
                AttributedTextPreview(attributedString: attrStr.adjustingColorsForCurrentAppearance())
            } else {
                textPreview(plain, monospaced: false)
            }
        case .image(let image, _, _):
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .cornerRadius(8)
        case .file(let url):
            filePreview(url)
        case .files(let urls):
            fileListPreview(urls)
        case .svg(let src):
            textPreview(src, monospaced: true)
        case .blob(let dict):
            textPreview(dict.keys.sorted().map { "· \($0)" }.joined(separator: "\n"), monospaced: true)
        }
    }

    private func validWebURL(_ text: String) -> URL? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.contains("\n"), !t.contains("\r"),
              let url = URL(string: t),
              url.scheme == "http" || url.scheme == "https",
              url.host != nil else { return nil }
        return url
    }

    private func textPreview(_ text: String, monospaced: Bool) -> some View {
        ScrollView {
            Text(text)
                .font(.system(size: 12, design: monospaced ? .monospaced : .default))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func filePreview(_ url: URL) -> some View {
        HStack(spacing: 8) {
            Image(nsImage: ClipenIconCache.shared.fileIcon(for: url))
                .resizable()
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(url.lastPathComponent)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text(url.path)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private func fileListPreview(_ urls: [URL]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(urls, id: \.path) { url in
                    HStack(spacing: 6) {
                        Image(nsImage: ClipenIconCache.shared.fileIcon(for: url))
                            .resizable()
                            .frame(width: 16, height: 16)
                        Text(url.lastPathComponent)
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                    }
                }
            }
        }
    }
}

// MARK: - Similar Items

private struct SimilarItemsScrollView: View {
    let pinned:   ClipboardItem
    let similars: [ClipboardItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "sparkle.magnifyingglass")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.secondary)
                Text("Similar items in clipboard")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            if similars.isEmpty {
                Text("No similar items found")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(similars) { sim in
                            SimilarItemCard(pinned: pinned, similar: sim)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                }
            }
        }
        .background(Color.primary.opacity(0.02))
    }
}

private struct SimilarItemCard: View {
    let pinned:  ClipboardItem
    let similar: ClipboardItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Type label
            HStack(spacing: 4) {
                Image(systemName: similar.iconName)
                    .font(.system(size: 9))
                    .foregroundColor(.accentColor)
                Text(similar.typeLabel)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
            }

            // Content with word-level diff highlight
            diffView
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)

            // Paste button
            Button {
                if let idx = ClipboardManager.shared.items.firstIndex(where: { $0.id == similar.id }) {
                    ClipboardManager.shared.pasteItem(at: idx)
                }
            } label: {
                Text("Paste")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .frame(width: 150, height: 130)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(Color.primary.opacity(0.08), lineWidth: 1))
    }

    @ViewBuilder
    private var diffView: some View {
        let pinnedText  = pinnedPlainText
        let similarText = similarPlainText
        if let p = pinnedText, let s = similarText {
            DiffHighlightText(baseText: p, compareText: s)
        } else if let s = similarText {
            Text(s)
                .font(.system(size: 10, design: .monospaced))
                .lineLimit(4)
                .foregroundColor(.primary)
        } else {
            Text(similar.typeLabel)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
    }

    private var pinnedPlainText: String? {
        switch pinned.content {
        case .text(let t):              return t
        case .richText(_, let t),
             .html(_, let t),
             .rtfd(_, let t):          return t
        default:                       return nil
        }
    }

    private var similarPlainText: String? {
        switch similar.content {
        case .text(let t):             return t
        case .richText(_, let t),
             .html(_, let t),
             .rtfd(_, let t):         return t
        default:                      return nil
        }
    }
}

/// Renders `compareText` with words that don't appear in `baseText` highlighted
/// in accent colour so differences jump out at a glance.
private struct DiffHighlightText: View {
    let baseText:    String
    let compareText: String

    var body: some View {
        let baseWords = Set(baseText.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { $0.count > 2 })

        let words = compareText
            .components(separatedBy: .whitespacesAndNewlines)
            .prefix(60)

        var result = Text("")
        var first  = true
        for word in words {
            if !first { result = result + Text(" ") }
            first = false
            let isNew = !baseWords.contains(word.lowercased())
            if isNew {
                result = result + Text(word)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.accentColor)
                    .bold()
            } else {
                result = result + Text(word)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.primary.opacity(0.7))
            }
        }
        return result.lineLimit(4)
    }
}

// MARK: - Annotation data types

struct AnnotationStroke: Codable, Identifiable, Equatable {
    var id       = UUID()
    var points:  [AnnotationPoint]
    var colorHex: String
    var width:   CGFloat
    var isEraser: Bool
}

struct AnnotationPoint: Codable, Equatable {
    var x: CGFloat
    var y: CGFloat
}

struct AnnotationTextItem: Codable, Identifiable {
    var id:         UUID   = UUID()
    var text:       String
    var xFraction:  CGFloat   // 0…1 relative to view width
    var yFraction:  CGFloat   // 0…1 relative to view height
    var colorHex:   String = "#FF3B30"
    var fontSize:   CGFloat = 15
}

// MARK: - Drawing canvas

struct AnnotationCanvasView: NSViewRepresentable {
    @Binding var strokes:     [AnnotationStroke]
    @Binding var strokeColor: Color
    @Binding var isEraser:    Bool

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> DrawingCanvasNSView {
        let view = DrawingCanvasNSView()
        view.onChange = { newStrokes in context.coordinator.parent.strokes = newStrokes }
        return view
    }

    func updateNSView(_ view: DrawingCanvasNSView, context: Context) {
        view.strokes     = strokes
        view.strokeColor = NSColor(strokeColor)
        view.isEraser    = isEraser
    }

    final class Coordinator {
        var parent: AnnotationCanvasView
        init(parent: AnnotationCanvasView) { self.parent = parent }
    }
}

final class DrawingCanvasNSView: NSView {
    var strokes:     [AnnotationStroke] = []
    var currentPts:  [CGPoint] = []
    var strokeColor: NSColor   = .systemRed
    var isEraser:    Bool      = false
    var strokeWidth: CGFloat   = 3
    var onChange:    (([AnnotationStroke]) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }
    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent)    { currentPts = [localPoint(event)] }
    override func mouseDragged(with event: NSEvent) { currentPts.append(localPoint(event)); needsDisplay = true }
    override func mouseUp(with event: NSEvent) {
        currentPts.append(localPoint(event))
        if currentPts.count > 1 {
            let hex = isEraser ? "#ERASER" : strokeColor.hexStringAnnotation
            let w   = isEraser ? 22.0 : strokeWidth
            strokes.append(AnnotationStroke(
                points: currentPts.map { AnnotationPoint(x: $0.x, y: $0.y) },
                colorHex: hex, width: w, isEraser: isEraser))
            onChange?(strokes)
        }
        currentPts = []
        needsDisplay = true
    }

    private func localPoint(_ event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill()
        for stroke in strokes { draw(stroke) }
        if currentPts.count > 1 {
            let live = AnnotationStroke(
                points: currentPts.map { AnnotationPoint(x: $0.x, y: $0.y) },
                colorHex: strokeColor.hexStringAnnotation, width: strokeWidth, isEraser: isEraser)
            draw(live)
        }
    }

    private func draw(_ stroke: AnnotationStroke) {
        guard stroke.points.count > 1 else { return }
        let path = NSBezierPath()
        path.move(to: CGPoint(x: stroke.points[0].x, y: stroke.points[0].y))
        for pt in stroke.points.dropFirst() { path.line(to: CGPoint(x: pt.x, y: pt.y)) }
        path.lineWidth    = stroke.width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        if stroke.isEraser {
            NSColor.white.withAlphaComponent(0.0).setStroke()
            if let ctx = NSGraphicsContext.current?.cgContext {
                ctx.saveGState(); ctx.setBlendMode(.clear); path.stroke(); ctx.restoreGState()
            }
        } else {
            (NSColor(hexString: stroke.colorHex) ?? .systemRed).setStroke()
            path.stroke()
        }
    }
}

// MARK: - Draggable text annotation

private struct DraggableAnnotationLabel: View {
    @Binding var label: AnnotationTextItem
    let onDelete: () -> Void

    @State private var isDragging = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Text(label.text)
                    .font(.system(size: label.fontSize, weight: .semibold))
                    .foregroundColor(Color(NSColor(hexString: label.colorHex) ?? .systemRed))
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 5))
                    .shadow(radius: 2)
                    .position(
                        x: label.xFraction * geo.size.width,
                        y: label.yFraction * geo.size.height
                    )
                    .gesture(
                        DragGesture()
                            .onChanged { val in
                                label.xFraction = max(0, min(1, val.location.x / geo.size.width))
                                label.yFraction = max(0, min(1, val.location.y / geo.size.height))
                            }
                    )
                    .contextMenu {
                        Button("Delete annotation", role: .destructive, action: onDelete)
                    }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Drawing toolbar

private struct AnnotationToolbar: View {
    @Binding var strokeColor: Color
    @Binding var isEraser:    Bool
    let onUndo:      () -> Void
    let onClear:     () -> Void
    @Binding var newTextInput: String
    let onAddText:   () -> Void

    private let presets: [Color] = [.red, .blue, .green, .orange, .yellow, .white, .black]

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                // Undo / Clear
                Button(action: onUndo)  { Image(systemName: "arrow.uturn.backward").font(.system(size: 11)) }.buttonStyle(.plain).help("Undo")
                Button(action: onClear) { Image(systemName: "trash").font(.system(size: 11)) }.buttonStyle(.plain).help("Clear all")

                Divider().frame(height: 14)

                // Pen / Eraser
                Button {
                    isEraser = false
                } label: {
                    Image(systemName: "pencil").font(.system(size: 11))
                        .foregroundColor(isEraser ? .secondary : .primary)
                }.buttonStyle(.plain).help("Pen")

                Button {
                    isEraser = true
                } label: {
                    Image(systemName: "eraser").font(.system(size: 11))
                        .foregroundColor(isEraser ? .accentColor : .secondary)
                }.buttonStyle(.plain).help("Eraser")

                Divider().frame(height: 14)

                // Color presets
                ForEach(presets, id: \.self) { c in
                    Circle().fill(c)
                        .frame(width: 14, height: 14)
                        .overlay(Circle().stroke(
                            c == strokeColor ? Color.primary.opacity(0.8) : Color.clear, lineWidth: 2))
                        .onTapGesture { strokeColor = c; isEraser = false }
                }
            }
            .padding(.horizontal, 10)

            // Text annotation row
            HStack(spacing: 6) {
                Image(systemName: "textformat").font(.system(size: 10)).foregroundColor(.secondary)
                TextField("Add label…", text: $newTextInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .onSubmit(onAddText)
                Button("Add", action: onAddText)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)
            }
            .padding(.horizontal, 10)
        }
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.04))
    }
}

// MARK: - NSColor hex helper

private extension NSColor {
    var hexStringAnnotation: String {
        guard let c = usingColorSpace(.deviceRGB) else { return "#FF3B30" }
        return String(format: "#%02X%02X%02X",
                      Int(c.redComponent * 255),
                      Int(c.greenComponent * 255),
                      Int(c.blueComponent * 255))
    }
}

private extension Color {
    var hexString: String {
        NSColor(self).hexStringAnnotation
    }
}
