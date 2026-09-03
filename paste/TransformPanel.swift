import AppKit
import SwiftUI

class TransformPanel: AnchoredPopoverPanel {
    private var cachedPanelHeight: CGFloat = 460
    private var cachedHeightSignature: Int? = nil

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
            case .group:                     return nil
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

        let heightSignature = displays.count
        let h: CGFloat
        if popover.isShown || cachedHeightSignature == heightSignature {
            h = cachedPanelHeight
        } else {
            let hv = NSHostingView(rootView: content)
            hv.layoutSubtreeIfNeeded()
            let measured = hv.fittingSize.height
            h = min(max(measured > 0 ? measured : 460, 360), 620)
            cachedPanelHeight = h
            cachedHeightSignature = heightSignature
        }

        present(content, size: NSSize(width: bubbleW, height: h),
                near: popupFrame, anchorPoint: anchorPoint)
    }
}

struct TransformView: View {
    let previewText:            String?
    let item:                   ClipboardItem
    let displays:               [TransformDisplay]
    let selectedTransformIndex: Int
    let isProcessing:           Bool
    let onDismiss:              () -> Void
    @ObservedObject private var manager = ClipboardManager.shared

    @Namespace private var selectionNamespace

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
        VStack(spacing: 0) {
            outerHeader
            Divider()
            middleToolList
            Divider()
            Text(stats)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
        }
    }

    private var outerHeader: some View {
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

                    VStack(spacing: 10) {
                        ForEach(Array(displays.enumerated()), id: \.element.id) { idx, display in
                            TransformRow(
                                display:    display,
                                isSelected: idx == selectedTransformIndex,
                                isProcessing: idx == selectedTransformIndex && isProcessing,
                                selectionNamespace: selectionNamespace
                            )
                            .equatable()
                            .id(idx)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) {
                                manager.uiApplyTransform(at: idx)
                            }
                            .onTapGesture(count: 1) {
                                manager.uiSelectTransform(at: idx)
                            }

                            if (display.id == "pdf.paste-pages" || display.id == "pdf.paste-pages-as-images")
                               && manager.inPageRangeMode
                               && display.id == activePagePickerToolID {
                                InlinePagePicker()
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

                                    .animation(.easeInOut(duration: 0.15), value: manager.inPageRangeMode)
                            }

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

                    let anchor: UnitPoint = newIdx == 0 ? .top : .center

                    withAnimation(SelectionHighlightStyle.spring) {
                        proxy.scrollTo(newIdx, anchor: anchor)
                    }
                }
                .onAppear {
                    guard displays.indices.contains(selectedTransformIndex) else { return }

                    if selectedTransformIndex > 0 {
                        proxy.scrollTo(selectedTransformIndex, anchor: .center)
                    }
                }
            }
        }
    }
}

struct TransformRow: View, Equatable {
    let display:      TransformDisplay
    let isSelected:   Bool
    let isProcessing: Bool

    let selectionNamespace: Namespace.ID

    static func == (lhs: TransformRow, rhs: TransformRow) -> Bool {
        lhs.display == rhs.display
            && lhs.isSelected == rhs.isSelected
            && lhs.isProcessing == rhs.isProcessing
    }

    @State private var isHovered = false

    private static let horizontalInset: CGFloat = 16

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: display.icon)
                .font(.system(size: 11))
                .foregroundColor(isSelected ? .white : .secondary)
                .frame(width: 16)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(LocalizedStringKey(display.label))
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

        .transaction { $0.animation = nil }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            (!isSelected && isHovered) ? Color.accentColor.opacity(0.1) : Color.clear,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .selectionHighlight(isSelected: isSelected, namespace: selectionNamespace,
                             inset: Self.horizontalInset)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovered)
    }
}
