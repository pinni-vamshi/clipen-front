import SwiftUI
import AppKit

struct MenuBarView: View {
    // ObservedObject (not StateObject) because these are app-wide singletons.
    // StateObject ties lifecycle to the View, which inside an NSHostingView
    // panel can prevent @Published updates from re-rendering. ObservedObject
    // properly subscribes to the existing singleton's publisher.
    @ObservedObject private var manager = ClipboardManager.shared
    @ObservedObject private var auth    = AuthManager.shared
    @Environment(\.openWindow) private var openWindow
    @State private var expandedItemID: UUID?  = nil
    @State private var showUpgradeToast = false
    @AppStorage("dismissedAccessibilityBanner") private var dismissedBanner = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if !manager.hasAccessibilityPermission && !dismissedBanner {
                permissionBanner
            }
            Divider()
            content
            Divider()
            firstOpenDelaySlider
            Divider()
            alwaysShowPreviewToggle
            Divider()
            footer
        }
        .frame(minWidth: 300, maxWidth: 520)
    }

    // (Get Pro banner + upgrade-toast removed with the account system.)

    // MARK: - Permission banner

    private var permissionBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Accessibility access needed")
                    .font(.caption.bold())
                Text("⌘V cycling won't work without it.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button("Open Settings") {
                NSWorkspace.shared.open(
                    URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
                )
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            // Dismiss × button — banner can be hidden if user wants to ignore the warning
            Button { dismissedBanner = true } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.secondary)
                    .padding(4)
            }
            .buttonStyle(.plain)
            .help("Hide this warning")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.1))
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            HStack(spacing: 8) {
                Image(nsImage: NSImage(named: "AppIcon") ?? NSImage())
                    .resizable()
                    .frame(width: 20, height: 20)
                    .cornerRadius(4)
                Text("Clipen")
                    .font(.headline)
            }
            Spacer()

            if !manager.items.isEmpty {
                Button { manager.clearAll() } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 13))
                        .foregroundColor(.red)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Item list

    @ViewBuilder
    private var content: some View {
        if manager.items.isEmpty {
            VStack(spacing: 10) {
                Spacer()
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 32))
                    .foregroundColor(.secondary.opacity(0.5))
                Text("Copy anything to get started")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            // ScrollView + LazyVStack instead of List — List has known
            // rendering issues inside NSHostingView/NSPanel contexts where
            // items would just not appear. Lazy stack is reliable.
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(spacing: 0) {
                    ForEach(Array(manager.displayItems.enumerated()), id: \.element.id) { index, item in
                        let isExpanded = expandedItemID == item.id

                        VStack(spacing: 0) {
                            ItemRow(
                                item: item,
                                index: index,
                                isSelected: index == manager.selectedIndex,
                                isExpanded: isExpanded,
                                onDelete: {
                                    if let real = manager.items.firstIndex(where: { $0.id == item.id }) {
                                        manager.removeItem(at: real)
                                    }
                                }
                            )
                            .onTapGesture {
                                withAnimation(.easeInOut(duration: 0.18)) {
                                    expandedItemID = isExpanded ? nil : item.id
                                }
                            }
                            .contextMenu {
                                Button("Move to front") {
                                    if let real = manager.items.firstIndex(where: { $0.id == item.id }) {
                                        manager.moveToFront(at: real)
                                    }
                                }
                                Button("Paste") {
                                    if let real = manager.items.firstIndex(where: { $0.id == item.id }) {
                                        manager.pasteItem(at: real)
                                    }
                                }
                                Divider()
                                Button(item.isPinned ? "Unpin" : "Pin") {
                                    manager.togglePin(id: item.id)
                                }
                                Button("Delete", role: .destructive) {
                                    if let real = manager.items.firstIndex(where: { $0.id == item.id }) {
                                        manager.removeItem(at: real)
                                    }
                                }
                            }

                            if isExpanded {
                                InlineTransformExpansion(item: item)
                            }
                            Divider()
                        }
                    }
                }
            }
            .frame(maxHeight: 400)
        }
    }

    // MARK: - First-open delay slider
    //
    // Lives here in the menu-bar widget (not just the main window) so the
    // user can A/B-test values in seconds without opening the full settings
    // sheet. Slider operates in milliseconds (UI granularity ~5 ms) and
    // writes the seconds-domain value back to the manager.

    private var firstOpenDelaySlider: some View {
        let delayMS = Binding<Double>(
            get: { manager.firstOpenDelay * 1000 },
            set: { manager.firstOpenDelay = $0 / 1000 }
        )
        return VStack(spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "timer")
                    .font(.system(size: 10))
                    .foregroundColor(manager.firstOpenDelay > 0 ? .accentColor : .secondary)
                Text("Open delay")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                Spacer()
                Text(manager.firstOpenDelay == 0
                     ? "Off"
                     : String(format: "%.0f ms", manager.firstOpenDelay * 1000))
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(manager.firstOpenDelay > 0 ? .accentColor : .secondary)
            }
            Slider(value: delayMS, in: 0...1000, step: 5)
                .tint(manager.firstOpenDelay > 0 ? .accentColor : .secondary)
            Text("Tap ⌘V and release inside this window to paste the front item without the popup.")
                .font(.system(size: 9))
                .foregroundColor(.secondary.opacity(0.85))
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - Always-show preview toggle

    private var alwaysShowPreviewToggle: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Image(systemName: "eye")
                    .font(.system(size: 10))
                    .foregroundColor(manager.alwaysShowItemPreview ? .accentColor : .secondary)
                Text("Always show preview")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                Spacer()
                Toggle("", isOn: $manager.alwaysShowItemPreview)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
            }
            Text(manager.alwaysShowItemPreview
                 ? "Preview follows the highlighted item while cycling."
                 : "Press Space while cycling to open preview.")
                .font(.system(size: 9))
                .foregroundColor(.secondary.opacity(0.85))
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Text("⌘V next · ⌥V +5 · ⌘X transform · ⌘⌫ delete")
                .font(.caption2)
                .foregroundColor(.secondary)
            Spacer()
            Button("Window") {
                AppDelegate.shared?.openMainWindow()
            }
            .buttonStyle(.plain)
            .font(.caption)
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

// MARK: - Item row

struct ItemRow: View {
    let item:       ClipboardItem
    let index:      Int
    let isSelected: Bool
    let isExpanded: Bool
    let onDelete:   () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {

            // ── Header: badge  type  ·  diff  ·  pin  X ─
            HStack(spacing: 8) {
                Text("\(index + 1)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundColor(isSelected ? .white : .secondary)
                    .frame(width: 20, height: 20)
                    .background(isSelected ? Color.accentColor : Color.secondary.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 5))

                ItemTagStrip(tags: item.tags, maxVisible: 3, compact: true)

                // Diff badge
                if let badge = item.diffBadge {
                    Text("∆ \(badge)")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundColor(.orange)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 3))
                }

                Spacer()

                // Expand/collapse chevron
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(isExpanded ? .accentColor : Color.secondary.opacity(0.35))

                // Pin — available to everyone now (no Pro tier).
                Button { ClipboardManager.shared.togglePin(id: item.id) } label: {
                    Image(systemName: item.isPinned ? "pin.fill" : "pin")
                        .font(.system(size: 10))
                        .foregroundColor(item.isPinned ? .accentColor : Color.secondary.opacity(0.4))
                }
                .buttonStyle(.plain)
                .help(item.isPinned ? "Unpin" : "Pin")

                Button(action: onDelete) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10))
                        .foregroundColor(Color.secondary.opacity(0.4))
                }
                .buttonStyle(.plain)
            }

            itemContent
                .padding(.leading, 28)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(isSelected ? Color.accentColor.opacity(0.08) : Color.clear)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var itemContent: some View {
        switch item.content {
        case .image(let img, _, _):
            Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 200, maxHeight: 70)
                .cornerRadius(5)
                .clipped()

        case .text(let str):
            HStack(alignment: .top, spacing: 6) {
                if ClipboardManager.shared.showColorSwatches, let c = item.detectedColor {
                    Circle().fill(Color(nsColor: c)).frame(width: 12, height: 12)
                        .overlay(Circle().stroke(Color.primary.opacity(0.2), lineWidth: 1))
                        .padding(.top, 1)
                }
                if let title = item.urlTitle {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Text(str).font(.system(size: 10, design: .monospaced)).lineLimit(1).foregroundColor(.secondary)
                    }
                } else {
                    Text(str).font(.system(size: 12, design: .monospaced)).lineLimit(3)
                }
            }

        case .richText(_, plain: let plain):
            Text(plain).font(.system(size: 12)).lineLimit(3)

        case .html(_, plain: let plain):
            Text(plain).font(.system(size: 12)).lineLimit(3)

        case .file(let url):
            HStack(spacing: 6) {
                fileThumbnail(url, size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(url.lastPathComponent).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Text(item.metadataSummary ?? url.deletingLastPathComponent().path)
                        .font(.system(size: 10)).lineLimit(1).foregroundColor(.secondary)
                }
            }

        case .files(let urls):
            HStack(spacing: 6) {
                if let firstImageURL = urls.first(where: FileKindDetector.isImageFile) {
                    fileThumbnail(firstImageURL, size: 34)
                } else {
                    Image(systemName: "doc.on.doc").frame(width: 16, height: 16)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(urls.count) files").font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Text(item.metadataSummary ?? urls.map(\.lastPathComponent).joined(separator: ", "))
                        .font(.system(size: 10)).lineLimit(1).foregroundColor(.secondary)
                }
            }

        case .svg(let src):
            Text(src).font(.system(size: 12, design: .monospaced)).lineLimit(3)

        case .blob(let typeMap):
            Text(typeMap.keys.sorted().joined(separator: ", "))
                .font(.system(size: 11)).lineLimit(2).foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private func fileThumbnail(_ url: URL, size: CGFloat) -> some View {
        if FileKindDetector.isImageFile(url), let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 5))
        } else {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 16, height: 16)
        }
    }
}

// MARK: - Inline expand: full content + transforms

struct InlineTransformExpansion: View {
    let item: ClipboardItem

    private var applicableTransforms: [ClipboardTool] {
        ToolRegistry.tools(for: item)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()

            // Full content
            Group {
                switch item.content {
                case .image(let img, _, _):
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: 180)
                        .cornerRadius(6)
                        .padding(10)

                case .text(let str):
                    ScrollView {
                        Text(str)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    }
                    .frame(maxHeight: 110)

                case .richText(_, plain: let plain):
                    ScrollView {
                        Text(plain)
                            .font(.system(size: 11))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    }
                    .frame(maxHeight: 110)

                case .html(_, plain: let plain):
                    ScrollView {
                        Text(plain)
                            .font(.system(size: 11))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    }
                    .frame(maxHeight: 110)

                case .file(let url):
                    HStack(spacing: 8) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                            .resizable().frame(width: 28, height: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(url.lastPathComponent).font(.system(size: 12, weight: .medium))
                            Text(item.metadataSummary ?? url.path).font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1)
                        }
                    }
                    .padding(10)

                case .files(let urls):
                    HStack(spacing: 8) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 24))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(urls.count) files").font(.system(size: 12, weight: .medium))
                            Text(item.metadataSummary ?? urls.map(\.lastPathComponent).joined(separator: ", "))
                                .font(.system(size: 10)).foregroundColor(.secondary).lineLimit(2)
                        }
                    }
                    .padding(10)

                case .svg(let src):
                    ScrollView {
                        Text(src)
                            .font(.system(size: 11, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    }
                    .frame(maxHeight: 110)

                case .blob(let typeMap):
                    Text(typeMap.keys.sorted().map { "· \($0)" }.joined(separator: "\n"))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
            }
            .background(Color.secondary.opacity(0.05))

            if !applicableTransforms.isEmpty {
                Divider()

                // Transforms list
                VStack(spacing: 0) {
                    HStack {
                        Text("TRANSFORMS")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.secondary)
                            .tracking(1.4)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)

                    ForEach(Array(applicableTransforms.prefix(8).enumerated()), id: \.element.id) { i, transform in
                        InlineTransformRow(item: item, transform: transform)
                        if i < min(applicableTransforms.count, 8) - 1 {
                            Divider().padding(.leading, 34)
                        }
                    }

                    if applicableTransforms.count > 8 {
                        Text("+\(applicableTransforms.count - 8) more — use ⌘X in cycling mode")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                    }
                }
            }
        }
        .background(Color.secondary.opacity(0.03))
    }
}

struct InlineTransformRow: View {
    let item:      ClipboardItem
    let transform: ClipboardTool
    @State private var isHovered = false

    private var preview: String? { transform.preview(item) }

    var body: some View {
        Button {
            if transform.isAsync {
                Task {
                    let result = await transform.runAsync(item)
                    await MainActor.run {
                        ClipboardManager.shared.applyTransformResult(result, restoring: item, toolID: transform.id)
                    }
                }
            } else if let result = transform.runSync?(item) {
                ClipboardManager.shared.applyTransformResult(result, restoring: item, toolID: transform.id)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: transform.icon)
                    .font(.system(size: 10))
                    .foregroundColor(isHovered ? .accentColor : .secondary)
                    .frame(width: 14)

                VStack(alignment: .leading, spacing: 2) {
                    Text(transform.label)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(isHovered ? .accentColor : .primary)
                    if let preview {
                        Text(preview.trimmingCharacters(in: .whitespacesAndNewlines))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                Spacer()

                if isHovered {
                    Image(systemName: "return")
                        .font(.system(size: 9))
                        .foregroundColor(.accentColor.opacity(0.6))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(isHovered ? Color.accentColor.opacity(0.08) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.1), value: isHovered)
    }
}
