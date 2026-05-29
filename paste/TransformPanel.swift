import AppKit
import SwiftUI

// MARK: - NSPanel

class TransformPanel: NSPanel {
    private var hostingView: NSHostingView<AnyView>?
    private var cachedPanelHeight: CGFloat = 460

    init() {
        super.init(
            contentRect: .zero,
            styleMask:   [.nonactivatingPanel, .borderless],
            backing:     .buffered,
            defer:       false
        )
        level           = .popUpMenu
        isOpaque        = false
        backgroundColor = .clear
        hasShadow       = false   // shadow drawn in SwiftUI — avoids double halo with NSPanel
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    func show(for item: ClipboardItem,
              near popupFrame: NSRect,
              anchorPoint: NSPoint? = nil,
              selectedTransformIndex: Int = 0,
              isProcessing: Bool = false,
              displaysOverride: [TransformDisplay]? = nil) {

        let previewText: String? = {
            switch item.content {
            case .text(let s):               return s
            case .richText(_, plain: let s): return s
            case .html(_, plain: let s):     return s
            case .file(let url):             return url.pathExtension.lowercased() == "pdf" ? nil : url.path
            case .files(let urls):           return urls.count == 1 ? urls[0].path : nil
            case .image:                     return nil
            case .svg(let src):              return src
            case .blob:                      return nil
            }
        }()

        let displays = displaysOverride ?? ToolRegistry.displays(for: item)

        let content = TransformView(
            previewText:            previewText,
            item:                   item,
            displays:               displays,
            selectedTransformIndex: selectedTransformIndex,
            isProcessing:           isProcessing,
            onDismiss:              { [weak self] in self?.hide() }
        )

        let bubbleW: CGFloat = 290
        let arrowW: CGFloat = 10
        let w: CGFloat = bubbleW + arrowW
        let screen = NSScreen.main?.visibleFrame ?? .zero

        let preferredRightX = popupFrame.maxX + 8
        let rightFits = preferredRightX + w <= screen.maxX
        let leftX = popupFrame.minX - w - 8
        let leftFits = leftX >= screen.minX + 8
        let placeRight = rightFits || !leftFits

        let measuringView = AnyView(TransformCalloutView(
            content: content,
            arrowOnLeadingSide: placeRight,
            arrowCenterYFromTop: 120
        ))

        // Always create a fresh NSHostingView — reusing it preserves the
        // inner SwiftUI tree (ScrollView offset, materialised rows,
        // @ObservedObject snapshots) across hide/show.
        let hv = NSHostingView(rootView: measuringView)
        contentView = hv
        hostingView = hv

        // When the panel is already visible (cycling with V), skip the
        // synchronous layout+fittingSize pass — it blocks the main thread
        // and causes lag when both preview and transform panels are open.
        // Use the cached height from the last full measurement instead.
        // On first show the panel is hidden, so we always measure then.
        let h: CGFloat
        if isVisible {
            h = cachedPanelHeight
        } else {
            hv.layoutSubtreeIfNeeded()
            let measured = hv.fittingSize.height
            h = min(max(measured > 0 ? measured : 460, 360), 620)
            cachedPanelHeight = h
        }

        var x = placeRight ? preferredRightX : leftX
        x = max(screen.minX + 8, x)

        let targetY = anchorPoint?.y ?? popupFrame.midY
        var y = targetY - h / 2
        y = max(screen.minY + 8, min(y, screen.maxY - h - 8))
        let arrowCenterYFromTop = (y + h) - targetY

        let finalView = AnyView(TransformCalloutView(
            content: content,
            arrowOnLeadingSide: placeRight,
            arrowCenterYFromTop: arrowCenterYFromTop
        ))
        // Swap rootView on the SAME instance to get the final geometry —
        // this is a normal SwiftUI update on a fresh tree, not the stale
        // reuse the recreation above is protecting against.
        hv.rootView = finalView

        setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
        contentView?.needsDisplay = true
        if !isVisible { orderFront(nil) }
    }

    func hide() { orderOut(nil) }
}

private struct TransformCalloutView: View {
    let content: TransformView
    let arrowOnLeadingSide: Bool
    let arrowCenterYFromTop: CGFloat

    var body: some View {
        HStack(spacing: -1) {
            if arrowOnLeadingSide {
                // Panel is on the right of the preview, so arrow must point left
                // back toward the selected row.
                sideArrow(pointingRight: false)
                content
            } else {
                content
                // Panel is on the left of the preview, so arrow must point right
                // back toward the selected row.
                sideArrow(pointingRight: true)
            }
        }
        // One shadow for arrow + bubble (panel hasShadow is off).
        .shadow(color: .black.opacity(0.22), radius: 16, x: 0, y: 6)
    }

    private func sideArrow(pointingRight: Bool) -> some View {
        GeometryReader { geo in
            let topOffset = max(12, min(arrowCenterYFromTop - 10, geo.size.height - 32))
            ZStack(alignment: .top) {
                Color.clear
                SideArrow(pointingRight: pointingRight)
                    .fill(.regularMaterial)
                    .frame(width: 10, height: 20)
                    .offset(y: topOffset)
            }
        }
        .frame(width: 10)
    }
}

private struct SideArrow: Shape {
    let pointingRight: Bool

    func path(in rect: CGRect) -> Path {
        var p = Path()
        if pointingRight {
            p.move(to: CGPoint(x: rect.maxX, y: rect.midY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        } else {
            p.move(to: CGPoint(x: rect.minX, y: rect.midY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        }
        p.closeSubpath()
        return p
    }
}

// MARK: - SwiftUI view

struct TransformView: View {
    let previewText:            String?
    let item:                   ClipboardItem
    let displays:               [TransformDisplay]
    let selectedTransformIndex: Int
    let isProcessing:           Bool
    let onDismiss:              () -> Void
    /// Observed so we can swap the body to the inline page-picker when the
    /// user activates the "Paste Specific Pages" transform — the panel's
    /// hosting view is set up once per show(), but the content reacts to
    /// manager state changes here.
    @ObservedObject private var manager = ClipboardManager.shared

    /// Which of the two PDF page-picker tool IDs the picker should currently
    /// expand under.  Derived from the manager's output-mode so the inline
    /// expansion always nests beneath the SAME tool the user activated.
    private var activePagePickerToolID: String {
        switch manager.pageRangeOutputMode {
        case .perPageImages: return "pdf.paste-pages-as-images"
        case .combinedPDF:   return "pdf.paste-pages"
        }
    }

    private var stats: String {
        guard let text = previewText else {
            switch item.content {
            case .image(let img, let data, _):
                let w = Int(img.size.width), h = Int(img.size.height)
                let kb = data.count / 1024
                return "\(w)x\(h) · \(kb) KB"
            case .file(let url):
                return item.metadataSummary ?? url.path
            case .files:
                return item.metadataSummary ?? item.previewText
            default:
                return ""
            }
        }
        let words = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.count
        let chars = text.count
        let lines = text.components(separatedBy: "\n").count
        return "\(words) words · \(chars) chars · \(lines) lines"
    }

    var body: some View {
        // Same outer chrome (header, detected-type badge, background, stroke)
        // regardless of mode — the panel must always look like the Transforms
        // panel.  Only the middle section swaps between the tool list and the
        // inline page picker so the user can see it's the SAME panel, with
        // one tool just expanded into an interactive form.
        VStack(spacing: 0) {
            outerHeader
            Divider()
            if let label = item.detectedType.badgeLabel {
                detectedBadge(label: label)
                Divider()
            }
            // ── Middle: the tool list is ALWAYS shown.  When the user has
            // activated "Paste Specific Pages", the picker UI expands
            // INLINE under that row — every other tool option stays visible
            // and the user keeps the full transform context.  Same pattern
            // would apply to any future interactive transform.
            middleToolList
            Divider()
            // Footer always shows the item's stats — the picker's keybindings
            // are advertised in the header (top-right) so we don't duplicate.
            Text(stats)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
        )
    }

    // MARK: - Outer chrome (always-on)

    private var outerHeader: some View {
        // Always renders the Transforms label — the picker now lives INLINE
        // under its tool row, so the header doesn't need to change context.
        HStack(spacing: 6) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
            Text("Transforms")
                .font(.system(size: 12, weight: .semibold))
            Spacer()
            Text(manager.inPageRangeMode
                 ? "↵ paste · ␣ preview · ⎋ cancel"
                 : "⌘X next · ⌘⇧X prev · release ⌘ apply")
                .font(.system(size: 9))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func detectedBadge(label: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: item.detectedType.sfIcon)
                .font(.system(size: 10, weight: .semibold))
            Text(label)
                .font(.system(size: 10, weight: .semibold))
            Spacer()
            Text("detected")
                .font(.system(size: 9))
                .foregroundColor(.secondary)
        }
        .foregroundColor(item.detectedType.badgeColor)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(item.detectedType.badgeColor.opacity(0.12))
    }

    // MARK: - Middle: tool list (used when not in page-range mode)

    @ViewBuilder
    private var middleToolList: some View {
        if displays.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "wand.and.stars.inverse")
                    .font(.system(size: 24, weight: .thin))
                    .foregroundColor(.secondary.opacity(0.4))
                Text("No transforms available")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary.opacity(0.6))
                Text("This content type can't be transformed")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.4))
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(displays.enumerated()), id: \.element.id) { idx, display in
                            TransformRow(
                                display:    display,
                                isSelected: idx == selectedTransformIndex,
                                isProcessing: idx == selectedTransformIndex && isProcessing
                            )
                            .id(idx)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) {
                                manager.uiApplyTransform(at: idx)
                            }
                            .onTapGesture(count: 1) {
                                manager.uiSelectTransform(at: idx)
                            }

                            // INLINE picker — nested directly under whichever
                            // PDF-page tool the user activated.  Two tools
                            // share the same picker UI; mode is set in
                            // ClipboardManager.pageRangeOutputMode and drives
                            // commit/preview behaviour (combined PDF vs.
                            // individual PNGs).  Other tool rows stay
                            // visible — no transform context is lost.
                            if (display.id == "pdf.paste-pages" || display.id == "pdf.paste-pages-as-images")
                               && manager.inPageRangeMode
                               && display.id == activePagePickerToolID {
                                InlinePagePicker()
                                    .padding(.leading, 36) // align under the tool row's label
                                    .padding(.trailing, 8)
                                    .padding(.vertical, 6)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(Color.accentColor.opacity(0.05))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(Color.accentColor.opacity(0.3), lineWidth: 1)
                                    )
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 4)
                                    .transition(.opacity.combined(with: .move(edge: .top)))
                            }

                            if idx < displays.count - 1 {
                                Divider().padding(.leading, 36)
                            }
                        }
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)
                    .animation(.easeInOut(duration: 0.15), value: manager.inPageRangeMode)
                }
                .onChange(of: selectedTransformIndex) { _, newIdx in
                    guard displays.indices.contains(newIdx) else { return }
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(newIdx, anchor: .center)
                    }
                }
                .onAppear {
                    guard displays.indices.contains(selectedTransformIndex) else { return }
                    proxy.scrollTo(selectedTransformIndex, anchor: .center)
                }
            }
        }
    }
}

// MARK: - Transform row

struct TransformRow: View {
    let display:      TransformDisplay
    let isSelected:   Bool
    let isProcessing: Bool

    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: display.icon)
                .font(.system(size: 11))
                .foregroundColor(isSelected ? .white : .secondary)
                .frame(width: 16)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(display.label)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(isSelected ? .white : .primary)
                    Spacer()
                    if isProcessing {
                        ProgressView()
                            .scaleEffect(0.55)
                            .tint(isSelected ? .white : .accentColor)
                    } else if isSelected {
                        HStack(spacing: 4) {
                            Text("Release")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(.white.opacity(0.85))
                            Text("⌘")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundColor(.white)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.white.opacity(0.2),
                                            in: RoundedRectangle(cornerRadius: 3))
                            Text("to paste")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(.white.opacity(0.85))
                        }
                    } else if isHovered {
                        Image(systemName: "return")
                            .font(.system(size: 9))
                            .foregroundColor(.accentColor.opacity(0.7))
                    }
                }
                if let preview = display.preview {
                    Text(preview.trimmingCharacters(in: .whitespacesAndNewlines))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(isSelected ? .white.opacity(0.75) : .secondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            isSelected
                ? Color.accentColor
                : (isHovered ? Color.accentColor.opacity(0.1) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovered)
        .animation(.easeInOut(duration: 0.12), value: isSelected)
    }
}

// MARK: - Shared content type badge

struct ContentTypeBadge: View {
    let type: ClipboardContentType

    var body: some View {
        if let label = type.badgeLabel {
            HStack(spacing: 3) {
                Image(systemName: type.sfIcon)
                    .font(.system(size: 7, weight: .bold))
                Text(label)
                    .font(.system(size: 8, weight: .bold))
            }
            .foregroundColor(type.badgeColor)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(type.badgeColor.opacity(0.15),
                        in: RoundedRectangle(cornerRadius: 4))
        }
    }
}

