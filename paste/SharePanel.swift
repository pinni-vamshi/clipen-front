import AppKit
import SwiftUI

class SharePanel: NSObject, NSPopoverDelegate {
    private let anchorPanel: NSPanel
    private let anchorView = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
    private let popover = NSPopover()
    private var cachedPanelHeight: CGFloat = 320
    // See TransformPanel's identical comment: keyed on content shape so a
    // fresh S press doesn't re-measure a throwaway view just to discard it.
    private var cachedHeightSignature: Int? = nil
    private var wantsVisible = false
    private var shownStrip: NSRect? = nil

    func popoverDidShow(_ notification: Notification) {
        popover.contentViewController?.view.window?.sharingType = .none
        if !wantsVisible {
            popover.performClose(nil)
            anchorPanel.orderOut(nil)
        }
    }

    var isVisible: Bool { wantsVisible && popover.isShown }

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

    func show(services: [NSSharingService], selectedIndex: Int, itemCount: Int,
              near popupFrame: NSRect, anchorPoint: NSPoint? = nil) {
        let content = ShareView(services: services, selectedIndex: selectedIndex, itemCount: itemCount)

        let bubbleW: CGFloat = 260
        let screen = NSScreen.main?.visibleFrame ?? .zero
        let preferredRightX = popupFrame.maxX + 8
        let rightFits = preferredRightX + bubbleW <= screen.maxX
        let leftFits = popupFrame.minX - bubbleW - 8 >= screen.minX + 8
        let placeRight = rightFits || !leftFits

        let heightSignature = services.count
        let h: CGFloat
        if popover.isShown || cachedHeightSignature == heightSignature {
            h = cachedPanelHeight
        } else {
            let hv = NSHostingView(rootView: content)
            hv.layoutSubtreeIfNeeded()
            let measured = hv.fittingSize.height
            h = min(max(measured > 0 ? measured : 220, 160), 420)
            cachedPanelHeight = h
            cachedHeightSignature = heightSignature
        }

        popover.contentSize = NSSize(width: bubbleW, height: h)
        if let hostingController = popover.contentViewController as? NSHostingController<ShareView> {
            hostingController.rootView = content
        } else {
            popover.contentViewController = NSHostingController(rootView: content)
        }

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

        if popover.isShown { popover.performClose(nil) }
        anchorPanel.setFrame(desiredStrip, display: false)
        if !anchorPanel.isVisible { anchorPanel.orderFront(nil) }
        shownStrip = desiredStrip
        let edge: NSRectEdge = placeRight ? .maxX : .minX
        WakeGuard.afterWakeSettle { [popover, anchorView] in
            popover.animates = false
            popover.show(relativeTo: rowRect, of: anchorView, preferredEdge: edge)
            popover.animates = true
            popover.clipenAnimateIn()
        }
    }

    func hide() {
        wantsVisible = false
        if popover.isShown {
            // Snap-close to avoid the animated fade visually overlapping
            // whatever panel replaces it (transform, item preview).
            popover.animates = false
            popover.performClose(nil)
            popover.animates = true
        }
        anchorPanel.orderOut(nil)
        shownStrip = nil
    }
}

struct ShareView: View {
    let services: [NSSharingService]
    let selectedIndex: Int
    let itemCount: Int

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            list
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                Text("Share")
                    .font(.system(size: 12, weight: .semibold))
                if itemCount > 1 {
                    Text("· \(itemCount) items")
                        .font(.system(size: 10)).foregroundColor(.secondary)
                }
                Spacer()
            }
            HStack(spacing: 14) {
                FlatHint(key: "S", label: "Next")
                FlatHint(key: "↵", label: "Send")
                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 9)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var list: some View {
        if services.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "square.and.arrow.up.trianglebadge.exclamationmark")
                    .font(.system(size: 24, weight: .thin))
                    .foregroundColor(.secondary.opacity(0.4))
                Text("No share destinations available")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary.opacity(0.6))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    // Spacing here (not 0) reserves the vertical room each
                    // row's own selection pop needs — see ShareRow's
                    // scaleEffect comment.
                    VStack(spacing: 14) {
                        ForEach(Array(services.enumerated()), id: \.offset) { idx, service in
                            ShareRow(service: service, isSelected: idx == selectedIndex)
                                .equatable()
                                .id(idx)
                                .contentShape(Rectangle())
                                .onTapGesture(count: 2) {
                                    ClipboardManager.shared.shareIndex = idx
                                    ClipboardManager.shared.commitShare()
                                }
                                .onTapGesture(count: 1) {
                                    ClipboardManager.shared.shareIndex = idx
                                    ClipboardManager.shared.refreshShareStagePanel()
                                }
                            if idx < services.count - 1 {
                                Divider().padding(.leading, 36)
                            }
                        }
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)
                }
                .onChange(of: selectedIndex) { _, newIdx in
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(newIdx, anchor: .center)
                    }
                }
                .onAppear {
                    proxy.scrollTo(selectedIndex, anchor: .center)
                }
            }
        }
    }
}

private struct ShareRow: View, Equatable {
    let service: NSSharingService
    let isSelected: Bool

    // Same pattern as TransformRow: `@State private var isHovered` is
    // intentionally left out of the equality contract.
    static func == (lhs: ShareRow, rhs: ShareRow) -> Bool {
        lhs.service === rhs.service && lhs.isSelected == rhs.isSelected
    }

    @State private var isHovered = false

    private static let restingInset:    CGFloat = 6
    private static let selectedScale:   CGFloat = 1.4

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: service.image).resizable().frame(width: 18, height: 18)
            Text(service.title)
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .foregroundColor(isSelected ? .white : .primary)
            Spacer()
            if isSelected {
                HStack(spacing: 4) {
                    Text("Release")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.white.opacity(0.85))
                    Text("⌘")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Color.white.opacity(0.2), in: RoundedRectangle(cornerRadius: 3))
                }
            } else if isHovered {
                Image(systemName: "return")
                    .font(.system(size: 9))
                    .foregroundColor(.accentColor.opacity(0.7))
            }
        }
        // Same reasoning as the main popup's `rowContent`: hard-block any
        // inherited animation so this row's own text/icon changes never
        // pick up the selection box's spring or its position travel.
        .transaction { $0.animation = nil }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(
            (!isSelected && isHovered) ? Color.accentColor.opacity(0.1) : Color.clear,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        // Each row draws its own independent highlight — no shared
        // namespace, no cross-row travel. Selection changes are a pop in
        // place, not a moving box.
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.accentColor)
                .opacity(isSelected ? 1 : 0)
        }
        .padding(.horizontal, Self.restingInset)
        // Anisotropic on purpose — same as the main popup: Y grows with the
        // spring (the visible "elevation" pop), X is pinned to 1.0. The
        // VStack's spacing (14pt) reserves the vertical clearance the pop
        // needs so it doesn't overlap neighboring rows.
        .scaleEffect(x: 1.0, y: isSelected ? Self.selectedScale : 1.0)
        .animation(isSelected
                   ? .spring(response: 0.32, dampingFraction: 0.5)
                   : .easeOut(duration: 0.24),
                   value: isSelected)
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovered)
    }
}
