import AppKit
import SwiftUI

class SharePanel: AnchoredPopoverPanel {
    private var cachedPanelHeight: CGFloat = 320
    private var cachedHeightSignature: Int? = nil

    func show(services: [NSSharingService], selectedIndex: Int, itemCount: Int,
              near popupFrame: NSRect, anchorPoint: NSPoint? = nil) {
        let content = ShareView(services: services, selectedIndex: selectedIndex, itemCount: itemCount)

        let bubbleW: CGFloat = 260

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

        present(content, size: NSSize(width: bubbleW, height: h),
                near: popupFrame, anchorPoint: anchorPoint)
    }
}

struct ShareView: View {
    let services: [NSSharingService]
    let selectedIndex: Int
    let itemCount: Int

    @Namespace private var selectionNamespace

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
                FlatHint(key: "⇧S", label: "Prev")
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

                    VStack(spacing: 10) {
                        ForEach(Array(services.enumerated()), id: \.offset) { idx, service in
                            ShareRow(service: service, isSelected: idx == selectedIndex, selectionNamespace: selectionNamespace)
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

                    withAnimation(SelectionHighlightStyle.spring) {
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

    let selectionNamespace: Namespace.ID

    static func == (lhs: ShareRow, rhs: ShareRow) -> Bool {
        lhs.service === rhs.service && lhs.isSelected == rhs.isSelected
    }

    @State private var isHovered = false

    private static let horizontalInset: CGFloat = 14

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

        .transaction { $0.animation = nil }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(
            (!isSelected && isHovered) ? Color.accentColor.opacity(0.1) : Color.clear,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .selectionHighlight(isSelected: isSelected, namespace: selectionNamespace,
                             inset: Self.horizontalInset)
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovered)
    }
}
