import AppKit
import SwiftUI

class SharePanel: NSObject, NSPopoverDelegate {
    private let anchorPanel: NSPanel
    private let anchorView = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
    private let popover = NSPopover()
    private var cachedPanelHeight: CGFloat = 320
    private var wantsVisible = false
    private var shownStrip: NSRect? = nil

    func popoverDidShow(_ notification: Notification) {
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

        let h: CGFloat
        if popover.isShown {
            h = cachedPanelHeight
        } else {
            let hv = NSHostingView(rootView: content)
            hv.layoutSubtreeIfNeeded()
            let measured = hv.fittingSize.height
            h = min(max(measured > 0 ? measured : 220, 160), 420)
            cachedPanelHeight = h
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
                    VStack(spacing: 0) {
                        ForEach(Array(services.enumerated()), id: \.offset) { idx, service in
                            ShareRow(service: service, isSelected: idx == selectedIndex)
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

private struct ShareRow: View {
    let service: NSSharingService
    let isSelected: Bool

    @State private var isHovered = false

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
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(
            isSelected ? Color.accentColor : (isHovered ? Color.accentColor.opacity(0.1) : Color.clear),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .padding(.horizontal, 6)
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovered)
        .animation(.easeInOut(duration: 0.12), value: isSelected)
    }
}
