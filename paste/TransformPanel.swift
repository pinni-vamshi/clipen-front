import AppKit
import SwiftUI

// MARK: - NSPanel

class TransformPanel: NSPanel {
    private var hostingView: NSHostingView<AnyView>?

    init() {
        super.init(
            contentRect: .zero,
            styleMask:   [.nonactivatingPanel, .borderless],
            backing:     .buffered,
            defer:       false
        )
        level           = .floating
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

        if let hv = hostingView {
            hv.rootView = measuringView
        } else {
            let hv = NSHostingView(rootView: measuringView)
            contentView = hv
            hostingView = hv
        }

        let h = min(hostingView?.fittingSize.height ?? 560, 620)

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
        hostingView?.rootView = finalView

        setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
        if !isVisible { orderFront(nil) }
    }

    func hide() { orderOut(nil) }

    func showUpgradePrompt(near popupFrame: NSRect) {
        let w: CGFloat = 300
        let h: CGFloat = 160
        let x = popupFrame.maxX + 8
        let y = popupFrame.midY - h / 2
        let hv = NSHostingView(rootView: UpgradePromptView())
        contentView = hv
        setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
        if !isVisible { orderFront(nil) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.hide() }
    }
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
        if manager.inPageRangeMode {
            // Picker takes over the whole panel — header included — because
            // the user is now in a different mode entirely.  Its own header
            // explains the context ("Pick pages to paste").
            InlinePagePicker()
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                )
        } else {
            transformListBody
        }
    }

    private var transformListBody: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                Text("Transforms")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("⌘X cycle · release ⌘ apply")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)

            Divider()

            if let label = item.detectedType.badgeLabel {
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

                Divider()
            }

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
                                if idx < displays.count - 1 {
                                    Divider().padding(.leading, 36)
                                }
                            }
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 8)
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

            Divider()

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
                    } else if isSelected || isHovered {
                        Image(systemName: "return")
                            .font(.system(size: 9))
                            .foregroundColor(isSelected ? .white.opacity(0.7) : .accentColor.opacity(0.7))
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

// MARK: - Upgrade prompt

struct UpgradePromptView: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.fill")
                .font(.system(size: 28))
                .foregroundColor(.orange)

            VStack(spacing: 6) {
                Text("Transforms are Pro")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.primary)
                Text("Upgrade to unlock text transforms,\nunlimited ring size, and more.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button("Upgrade to Pro ->") {
                NSWorkspace.shared.open(URL(string: "https://clipen.app/upgrade")!)
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background(Color.orange, in: RoundedRectangle(cornerRadius: 7))
            .buttonStyle(.plain)
        }
        .padding(20)
        .frame(width: 300, height: 160)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(Color.orange.opacity(0.3), lineWidth: 1))
    }
}
