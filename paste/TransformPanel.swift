import AppKit
import SwiftUI

/// Real system NSPopover, anchored through an invisible helper panel — same
/// pattern as PreviewOverlayWindow and ItemPreviewPanel (see the header
/// comment on PreviewOverlayWindow for the full rationale). AppKit now draws
/// the rounded box, vibrancy, arrow, and entrance animation itself, anchored
/// at the highlighted row's actual screen position via `anchorPoint`
/// (computed by `PreviewOverlayWindow.selectedRowAnchorPoint`).
class TransformPanel: NSObject, NSPopoverDelegate {
    private let anchorPanel: NSPanel
    private let anchorView = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
    private let popover = NSPopover()
    private var cachedPanelHeight: CGFloat = 460
    /// True from show until hide — closes the animating-in race where hide()
    /// finds popover.isShown still false, skips the close, and the panel
    /// finishes presenting as an orphan after the popup is gone.
    private var wantsVisible = false

    func popoverDidShow(_ notification: Notification) {
        if !wantsVisible {
            popover.performClose(nil)
            anchorPanel.orderOut(nil)
        }
    }
    /// The anchor strip's frame for the CURRENT popover session, nil when
    /// hidden. The strip is placed once per session and never moved while the
    /// popover is shown — see show() for why that invariant matters.
    private var shownStrip: NSRect? = nil

    /// `wantsVisible` is ANDed in because NSPopover's close is animated:
    /// popover.isShown stays true until the close animation finishes, so
    /// guards running right after hide() saw a stale "still visible" and
    /// could re-present a panel that was being dismissed. Intent flips
    /// instantly; isShown alone doesn't. (Same fix as the sibling panels.)
    var isVisible: Bool { wantsVisible && popover.isShown }
    var frame: NSRect {
        // The popover WINDOW's frame includes AppKit chrome (arrow + shadow
        // padding) — callers doing anchor math need the actual content rect.
        if let view = popover.contentViewController?.view, let win = view.window {
            return win.convertToScreen(view.convert(view.bounds, to: nil))
        }
        return anchorPanel.frame
    }

    override init() {
        anchorPanel = NSPanel(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        anchorPanel.isOpaque = false
        anchorPanel.backgroundColor = .clear
        anchorPanel.hasShadow = false
        anchorPanel.ignoresMouseEvents = true
        anchorPanel.level = .popUpMenu
        anchorPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        anchorPanel.contentView = anchorView

        super.init()

        popover.behavior = .applicationDefined
        popover.animates = true
        popover.delegate = self
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
            case .rtfd(_, plain: let s):     return s
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
        let screen = NSScreen.main?.visibleFrame ?? .zero

        let preferredRightX = popupFrame.maxX + 8
        let rightFits = preferredRightX + bubbleW <= screen.maxX
        let leftFits = popupFrame.minX - bubbleW - 8 >= screen.minX + 8
        let placeRight = rightFits || !leftFits

        // When the panel is already visible (cycling with V), skip the
        // synchronous layout+fittingSize pass — it blocks the main thread
        // and causes lag when both preview and transform panels are open.
        // Use the cached height from the last full measurement instead.
        // On first show the panel is hidden, so we always measure then
        // (with a throwaway hosting view, created only in that branch).
        let h: CGFloat
        if popover.isShown {
            h = cachedPanelHeight
        } else {
            let hv = NSHostingView(rootView: content)
            hv.layoutSubtreeIfNeeded()
            let measured = hv.fittingSize.height
            h = min(max(measured > 0 ? measured : 460, 360), 620)
            cachedPanelHeight = h
        }

        popover.contentSize = NSSize(width: bubbleW, height: h)
        if let hostingController = popover.contentViewController as? NSHostingController<TransformView> {
            hostingController.rootView = content
        } else {
            popover.contentViewController = NSHostingController(rootView: content)
        }

        // The anchor is a stationary 1pt-wide strip spanning the popup's full
        // height at whichever edge the panel sits on, placed ONCE per popover
        // session and NEVER moved while the popover is shown. The previous
        // approach — teleporting a 1×1 anchor window to the new row on every
        // cycle and re-calling show() — broke AppKit's popover attachment:
        // moving the anchor window under a live popover tears it down, and
        // the re-show re-presents it, replaying the full close+open animation
        // on every single keystroke. Tracking the highlighted row is done the
        // supported way instead: updating `positioningRect` WITHIN the
        // stationary strip, which moves the arrow without any re-present.
        let anchorY = anchorPoint?.y ?? popupFrame.midY
        let stripHeight = max(1, popupFrame.height)
        let desiredStrip = NSRect(x: placeRight ? popupFrame.maxX : popupFrame.minX,
                                  y: popupFrame.minY, width: 1, height: stripHeight)
        let localY = max(0, min(stripHeight - 1, anchorY - desiredStrip.minY))
        let rowRect = NSRect(x: 0, y: localY, width: 1, height: 1)

        wantsVisible = true
        if popover.isShown, shownStrip == desiredStrip {
            popover.positioningRect = rowRect
            return
        }

        // Fresh show — or the popup frame / side changed (rare), which needs
        // a genuine re-present since the strip itself must move.
        if popover.isShown { popover.performClose(nil) }
        anchorPanel.setFrame(desiredStrip, display: false)
        if !anchorPanel.isVisible { anchorPanel.orderFront(nil) }
        shownStrip = desiredStrip
        // Fast open with a REAL visible animation — see clipenAnimateIn.
        // animates is restored so the close keeps the native fade-out.
        popover.animates = false
        popover.show(relativeTo: rowRect, of: anchorView,
                     preferredEdge: placeRight ? .maxX : .minX)
        popover.animates = true
        popover.clipenAnimateIn()
    }

    func hide() {
        wantsVisible = false
        if popover.isShown { popover.performClose(nil) }
        anchorPanel.orderOut(nil)
        shownStrip = nil
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
                detectedBadge(type: item.detectedType, label: label)
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
        // No background/clipShape/overlay here — hosted inside a real
        // NSPopover now, which draws all of that (plus the arrow) itself.
    }

    // MARK: - Outer chrome (always-on)

    private var outerHeader: some View {
        // Always renders the Transforms label — the picker now lives INLINE
        // under its tool row, so the header doesn't need to change context.
        // Hints render on their own full-width row below the title (not
        // crammed to the right of it), using the same icon + short-label
        // FlatHint style as the main popup's header hints.
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                Text("Transforms")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
            }

            HStack(spacing: 14) {
                if manager.inPageRangeMode {
                    FlatHint(key: "↵", label: "Paste")
                    FlatHint(key: "␣", label: "Preview", isActive: manager.popupHintSpace)
                    FlatHint(key: "⎋", label: "Cancel")
                } else if manager.inLanguagePickerMode {
                    FlatHint(key: "↑↓", label: "Choose")
                    FlatHint(key: "↵", label: "Translate")
                    FlatHint(key: "⎋", label: "Cancel")
                } else {
                    FlatHint(key: "X", label: "Next", isActive: manager.popupHintX)
                    FlatHint(key: "⇧X", label: "Prev", isActive: manager.popupHintShiftX)
                    FlatHint(key: "hold X", label: "Close", isActive: manager.popupHintXHold)
                }
                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 9)
        .padding(.bottom, 8)
    }

    private func detectedBadge(type: ClipboardContentType, label: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: type.sfIcon)
                .font(.system(size: 10, weight: .semibold))
            Text(label)
                .font(.system(size: 10, weight: .semibold))
            Spacer()
            Text("detected")
                .font(.system(size: 9))
                .foregroundColor(.secondary)
        }
        .foregroundColor(type.badgeColor)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(type.badgeColor.opacity(0.12))
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

                            // Same nested-inline-picker pattern as the PDF page
                            // picker above, for the "Translate" row.
                            if display.id == "ai.translate" && manager.inLanguagePickerMode {
                                InlineLanguagePicker()
                                    .padding(.leading, 36)
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
                    .animation(.easeInOut(duration: 0.15), value: manager.inLanguagePickerMode)
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
                : (isHovered ? Color.accentColor.opacity(0.1) : Color.clear),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .padding(.horizontal, 6)
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

