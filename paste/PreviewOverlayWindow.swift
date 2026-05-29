import AppKit
import SwiftUI

// MARK: - NSPanel

class PreviewOverlayWindow: NSPanel {

    private var visibleRowCount: Int = 5

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        level = .popUpMenu
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    /// Show popup anchored to the active text field's caret, falling back to
    /// screen-center if no focused text input is found.
    func show() {
        let anchor = caretScreenRect()
        showAnchored(to: anchor)
    }

    func showCentered() { showAnchored(to: nil) }

    func hide() { orderOut(nil) }

    // MARK: - Positioning

    private func showAnchored(to caretRect: NSRect?) {
        let rowH: CGFloat    = 72
        let headerH: CGFloat = 80
        let filterH: CGFloat = 36
        let footerH: CGFloat = 26
        let w: CGFloat       = 420
        let margin: CGFloat  = 12
        let maxVisible: Int  = 5

        let screen = NSScreen.main?.visibleFrame
                  ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        let slots = min(maxVisible, max(1, Int((screen.height - margin * 2 - headerH - filterH - footerH) / rowH)))
        let bodyH = headerH + filterH + CGFloat(slots) * rowH + footerH

        visibleRowCount = slots

        let x: CGFloat
        let y: CGFloat

        if let caret = caretRect {
            // Horizontally: center popup on the caret, clamped to screen.
            x = max(screen.minX + margin,
                    min(caret.midX - w / 2, screen.maxX - w - margin))
            // Vertically: prefer above the caret; fall back below if not enough space.
            let aboveY = caret.minY - bodyH - 6
            let belowY = caret.maxY + 6
            if aboveY >= screen.minY + margin {
                y = aboveY
            } else if belowY + bodyH <= screen.maxY - margin {
                y = belowY
            } else {
                // Not enough space either way — center vertically.
                y = screen.midY - bodyH / 2
            }
        } else {
            x = screen.midX - w / 2
            y = screen.midY - bodyH / 2
        }

        let hv = NSHostingView(rootView: PopoverPreviewView(visibleCount: slots))
        contentView = hv
        setFrame(NSRect(x: x, y: y, width: w, height: bodyH), display: true)
        if !isVisible { orderFront(nil) }
    }

    // MARK: - Caret lookup via Accessibility

    /// Returns the screen rect (macOS bottom-left origin) of the insertion point
    /// in the frontmost app's focused text element, or nil if unavailable.
    private func caretScreenRect() -> NSRect? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return nil }
        let appElement = AXUIElementCreateApplication(frontApp.processIdentifier)

        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement,
                                            kAXFocusedUIElementAttribute as CFString,
                                            &focusedRef) == .success,
              let focusedRef else { return nil }
        let focused = focusedRef as! AXUIElement  // swiftlint:disable:this force_cast

        // Verify the element is a text-editable role before trusting caret data.
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(focused, kAXRoleAttribute as CFString, &roleRef)
        let role = roleRef as? String ?? ""
        let textRoles: Set<String> = [
            kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole,
            "AXSearchField", "AXTextField", "AXTextArea", "AXWebArea"
        ]
        guard textRoles.contains(role) || role.hasPrefix("AXText") else { return nil }

        // Try to get insertion-point bounds via parameterised range attribute.
        var rangeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(focused,
                                         kAXSelectedTextRangeAttribute as CFString,
                                         &rangeRef) == .success,
           let rangeRef {
            var boundsRef: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(focused,
                                                          kAXBoundsForRangeParameterizedAttribute as CFString,
                                                          rangeRef,
                                                          &boundsRef) == .success,
               let boundsRef {
                var cgRect = CGRect.zero
                // AXValueGetValue needs the exact AXValue type.
                if AXValueGetValue(boundsRef as! AXValue, .cgRect, &cgRect),  // swiftlint:disable:this force_cast
                   cgRect != .zero {
                    return flipToMacOS(cgRect)
                }
            }
        }

        // Fallback: use the element's own frame.
        var frameRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(focused, "AXFrame" as CFString, &frameRef) == .success,
           let frameRef {
            var cgRect = CGRect.zero
            if AXValueGetValue(frameRef as! AXValue, .cgRect, &cgRect), cgRect != .zero {  // swiftlint:disable:this force_cast
                return flipToMacOS(cgRect)
            }
        }

        return nil
    }

    /// Converts a CGRect in screen-flipped coordinates (top-left origin, as
    /// returned by the Accessibility API) to macOS window-server coordinates
    /// (bottom-left origin, as used by NSWindow.frame).
    private func flipToMacOS(_ rect: CGRect) -> NSRect {
        let screenH = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: rect.minX,
                      y: screenH - rect.maxY,
                      width: max(rect.width, 1),
                      height: max(rect.height, 1))
    }

    /// Center Y of the currently-selected visible row — used by sibling panels
    /// (transform callout, item preview) to anchor their arrows.
    func selectedRowAnchorPoint(selectedIndex: Int, totalItems: Int) -> NSPoint {
        guard totalItems > 0 else { return NSPoint(x: frame.maxX, y: frame.midY) }

        let win            = min(max(1, visibleRowCount), totalItems)
        let clampedStart   = max(0, min(selectedIndex < win ? 0 : selectedIndex - (win - 1),
                                        totalItems - win))
        let rowInWindow    = max(0, min(selectedIndex - clampedStart, win - 1))
        let rowH: CGFloat  = 72
        let footerH: CGFloat = 26
        let rowsBottomY    = frame.minY + footerH
        let rowCenterY     = rowsBottomY + (CGFloat(win - rowInWindow) - 0.5) * rowH

        return NSPoint(x: frame.maxX, y: rowCenterY)
    }
}

// MARK: - Popup SwiftUI view

struct PopoverPreviewView: View {

    let visibleCount: Int

    @ObservedObject private var manager = ClipboardManager.shared
    @ObservedObject private var auth    = AuthManager.shared

    // Popup always renders from displayItems — the exact same array that
    // keyboard navigation (V/⌘V) and paste use. One array, one index,
    // zero mismatch possible.
    private var items: [ClipboardItem] { manager.displayItems }
    private var selectedIndex: Int     { manager.selectedIndex }

    private static let rowH: CGFloat = 72

    var body: some View {
        VStack(spacing: 0) {
            header
            categoryStrip
            firstCycleHint
            Divider()
            rowArea
            Divider()
            footer
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.primary.opacity(0.1), lineWidth: 1))
        .shadow(color: .black.opacity(0.22), radius: 16, x: 0, y: 6)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 14) {
            Button { manager.replayPopupCoach() } label: {
                HStack(spacing: 8) {
                    Image(nsImage: NSImage(named: "AppIcon") ?? NSImage())
                        .resizable().frame(width: 18, height: 18).cornerRadius(4)
                    Text("Clipen")
                        .font(.system(.callout, weight: .semibold))
                        .foregroundColor(.primary).lineLimit(1).fixedSize()
                }
            }
            .buttonStyle(.plain)
            .help("Show how Clipen works again")

            Spacer()

            FlatHint(key: "V", label: "Next", isActive: manager.popupHintV)
                .overlay(alignment: .bottom) {
                    if manager.popupCoachStep == 0
                    || (manager.coachReplayActive && manager.coachReplayStep == 0) {
                        CoachBubble(text: "Hold ⌘ and tap V a few times to cycle items")
                            .offset(y: 38).allowsHitTesting(false)
                    }
                }

            FlatHint(key: "⇧V", label: "Prev", isActive: manager.popupHintShiftV)

            FlatHint(key: "X", label: "Transform",
                     enabled: auth.transformsEnabled,
                     isActive: manager.popupHintX)
                .overlay(alignment: .bottom) {
                    if manager.popupCoachStep == 1
                    || (manager.coachReplayActive && manager.coachReplayStep == 1) {
                        CoachBubble(text: "Tap X a few times to cycle transforms")
                            .offset(y: 38).allowsHitTesting(false)
                    }
                }

            SpaceKeyFlatHint(label: "Preview", isActive: manager.popupHintSpace)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: Category strip (popup-only — popupTagFilter, never touches main window)

    private var categoryStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                TagFilterChip(tag: nil, selected: manager.popupTagFilter == nil, shortcutNumber: 1) {
                    manager.popupTagFilter = nil
                }
                ForEach(manager.availableTags, id: \.self) { tag in
                    TagFilterChip(
                        tag: tag,
                        selected: manager.popupTagFilter == tag,
                        shortcutNumber: (manager.availableTags.firstIndex(of: tag) ?? 0) + 2
                    ) {
                        manager.popupTagFilter = tag
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
        .frame(height: 36)
        .background(Color.primary.opacity(0.02))
    }

    // MARK: First-cycle hint banner

    @ViewBuilder
    private var firstCycleHint: some View {
        if manager.showFirstCycleHint {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").font(.system(size: 10, weight: .semibold))
                Text("Tip: Tap X to transform the highlighted item")
                    .font(.system(size: 11, weight: .medium))
                Spacer()
            }
            .foregroundColor(.white)
            .padding(.horizontal, 14).padding(.vertical, 6)
            .background(LinearGradient(colors: [Color(hex: "#4F8EF7"), Color(hex: "#A855F7")],
                                       startPoint: .leading, endPoint: .trailing))
            .transition(.opacity)
        }
    }

    // MARK: Row area

    private var rowArea: some View {
        normalRingArea
            .frame(height: Self.rowH * CGFloat(visibleCount), alignment: .top)
    }

    private var normalRingArea: some View {
        Group {
            if items.isEmpty {
                Text("No items with this tag")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: true) {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                                PopoverRow(item: item, index: idx,
                                           isSelected: manager.selectionArmed && idx == selectedIndex)
                                    .id(item.id)
                                    .contentShape(Rectangle())
                                    .onTapGesture(count: 2) {
                                        manager.uiSelectItem(at: idx)
                                        manager.commitPaste()
                                    }
                                    .onTapGesture(count: 1) {
                                        manager.uiSelectItem(at: idx)
                                    }
                                if idx < items.count - 1 {
                                    Divider().padding(.leading, 38)
                                }
                            }
                        }
                    }
                    .onChange(of: selectedIndex) { _, newIdx in
                        guard items.indices.contains(newIdx) else { return }
                        withAnimation(.easeOut(duration: 0.12)) {
                            proxy.scrollTo(items[newIdx].id, anchor: .center)
                        }
                    }
                    .onAppear {
                        guard items.indices.contains(selectedIndex) else { return }
                        proxy.scrollTo(items[selectedIndex].id, anchor: .center)
                    }
                }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        Text(items.isEmpty
             ? "0 of 0"
             : "\(min(selectedIndex + 1, items.count)) of \(items.count)")
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
    }
}

// MARK: - Row

struct PopoverRow: View {
    let item:       ClipboardItem
    let index:      Int
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            rowHeader
            rowContent.padding(.leading, 30)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(isSelected ? Color.accentColor.opacity(0.40) : Color.clear, in: Rectangle())
        .overlay(alignment: .leading) {
            if isSelected {
                Rectangle().fill(Color.accentColor).frame(width: 3)
            }
        }
    }

    private var rowHeader: some View {
        HStack(spacing: 8) {
            ItemTagStrip(tags: item.tags, maxVisible: 4, style: .plainComma)

            if item.isSecret {
                HStack(spacing: 3) {
                    Image(systemName: "lock.fill").font(.system(size: 8, weight: .bold))
                    Text("Secret").font(.system(size: 8, weight: .bold))
                }
                .foregroundColor(.red)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Color.red.opacity(0.14), in: RoundedRectangle(cornerRadius: 3))
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.red.opacity(0.35), lineWidth: 0.5))
                .help("Detected as a likely secret. Stored encrypted at rest.")
            }

            if let badge = item.diffBadge {
                Text("∆ \(badge)")
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .foregroundColor(.orange)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 3))
            }

            Spacer()

            if isSelected {
                HStack(spacing: 4) {
                    Text("Release").font(.system(size: 9, weight: .medium)).foregroundColor(.accentColor.opacity(0.85))
                    Text("⌘")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(.accentColor)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 3))
                    Text("to paste").font(.system(size: 9, weight: .medium)).foregroundColor(.accentColor.opacity(0.85))
                }
            }
        }
    }

    @ViewBuilder
    private var rowContent: some View {
        switch item.content {
        case .text(let str):
            if let title = item.urlTitle {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1).foregroundColor(.primary)
                    Text(str).font(.system(size: 10, design: .monospaced)).lineLimit(1).foregroundColor(.primary.opacity(0.6))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(spacing: 6) {
                    if ClipboardManager.shared.showColorSwatches, let c = item.detectedColor {
                        Circle().fill(Color(nsColor: c)).frame(width: 12, height: 12)
                            .overlay(Circle().stroke(Color.primary.opacity(0.2), lineWidth: 1))
                    }
                    Text(str).font(.system(size: 12, design: .monospaced)).lineLimit(2)
                        .foregroundColor(.primary).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        case .richText(_, plain: let plain):
            Text(plain).font(.system(size: 12)).lineLimit(2).foregroundColor(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .html(_, plain: let plain):
            Text(plain).font(.system(size: 12)).lineLimit(2).foregroundColor(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .file(let url):
            HStack(spacing: 6) {
                fileThumbnail(url, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(url.lastPathComponent).font(.system(size: 11, weight: .medium)).lineLimit(1)
                    Text(item.metadataSummary ?? url.deletingLastPathComponent().path)
                        .font(.system(size: 9)).lineLimit(1).foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .files(let urls):
            HStack(spacing: 6) {
                if let first = urls.first(where: FileKindDetector.isImageFile) {
                    fileThumbnail(first, size: 28)
                } else {
                    Image(systemName: "doc.on.doc").frame(width: 14, height: 14)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(urls.count) files").font(.system(size: 11, weight: .medium)).lineLimit(1)
                    Text(item.metadataSummary ?? urls.map(\.lastPathComponent).joined(separator: ", "))
                        .font(.system(size: 9)).lineLimit(1).foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .image(let img, _, _):
            VStack(alignment: .leading, spacing: 2) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 280, maxHeight: 48).cornerRadius(5).clipped()
                if let summary = item.metadataSummary {
                    Text(summary).font(.system(size: 9)).lineLimit(1).foregroundColor(.secondary)
                }
            }
        case .svg(let src):
            Text(src).font(.system(size: 11, design: .monospaced)).lineLimit(2)
                .foregroundColor(.primary).frame(maxWidth: .infinity, alignment: .leading)
        case .blob(let typeMap):
            VStack(alignment: .leading, spacing: 2) {
                Text("Private clipboard data")
                    .font(.system(size: 11, weight: .medium)).foregroundColor(.primary)
                Text(typeMap.keys.sorted().joined(separator: "  ·  "))
                    .font(.system(size: 9, design: .monospaced)).lineLimit(1).foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func fileThumbnail(_ url: URL, size: CGFloat) -> some View {
        AsyncFileThumbnail(url: url, size: size)
    }
}

// MARK: - Async file thumbnail (loads icon/image off main thread)

private struct AsyncFileThumbnail: View {
    let url: URL
    let size: CGFloat
    @State private var image: NSImage? = nil

    var body: some View {
        Group {
            if let img = image {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: 5))
            } else {
                RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.08))
                    .frame(width: size, height: size)
            }
        }
        .task(id: url) {
            let loaded = await Task.detached(priority: .utility) { () -> NSImage? in
                if FileKindDetector.isImageFile(url),
                   let img = NSImage(contentsOf: url) { return img }
                return NSWorkspace.shared.icon(forFile: url.path)
            }.value
            image = loaded
        }
    }
}

// MARK: - Category filter chip

struct TagFilterChip: View {
    let tag:     ClipboardTag?
    let selected: Bool
    var shortcutNumber: Int? = nil
    var customIcon:  String? = nil
    var customLabel: String? = nil
    let action: () -> Void

    private var icon:  String { customIcon  ?? tag?.icon  ?? "clock" }
    private var label: String { customLabel ?? tag?.label ?? "Recents" }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let n = shortcutNumber {
                    Text("\(n).")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(selected ? .white.opacity(0.85) : .secondary.opacity(0.75))
                }
                Image(systemName: icon).font(.system(size: 9, weight: .semibold))
                Text(label).font(.system(size: 10, weight: .semibold))
            }
            .foregroundColor(selected ? .white : .secondary)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Capsule(style: .continuous)
                .fill(selected ? AnyShapeStyle(Color.accentColor)
                               : AnyShapeStyle(Color.primary.opacity(0.08))))
            .overlay(Capsule(style: .continuous)
                .stroke(selected ? Color.clear : Color.primary.opacity(0.06), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Header hint views

struct FlatHint: View {
    private static let activeColor = Color(hex: "#4F8EF7")

    let key:   String
    let label: String
    var enabled:  Bool = true
    var isActive: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(isActive ? Self.activeColor : .primary)
                .lineLimit(1).fixedSize()
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(isActive ? Self.activeColor : .secondary)
                .lineLimit(1).fixedSize()
        }
        .fixedSize()
        .opacity(enabled ? 1.0 : 0.35)
        .animation(.easeOut(duration: 0.1), value: isActive)
    }
}

struct SpaceKeyFlatHint: View {
    private static let activeColor = Color(hex: "#4F8EF7")

    let label:    String
    var enabled:  Bool = true
    var isActive: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .stroke(isActive ? Self.activeColor : Color.primary.opacity(0.45), lineWidth: 1)
                    .frame(width: 18, height: 10)
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(isActive ? Self.activeColor : Color.primary.opacity(0.7))
                    .frame(width: 10, height: 1.5)
            }
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(isActive ? Self.activeColor : .secondary)
                .lineLimit(1).fixedSize()
        }
        .fixedSize()
        .opacity(enabled ? 1.0 : 0.35)
        .animation(.easeOut(duration: 0.1), value: isActive)
    }
}

// MARK: - First-run coach bubble

struct CoachBubble: View {
    let text: String
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 3) {
            Triangle().fill(Color.accentColor).frame(width: 9, height: 5)
            Text(text)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 6))
                .fixedSize()
        }
        .shadow(color: .accentColor.opacity(0.4), radius: pulse ? 8 : 3, x: 0, y: 2)
        .scaleEffect(pulse ? 1.04 : 1.0)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
        }
    }
}

struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}
