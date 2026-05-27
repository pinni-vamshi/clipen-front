import AppKit
import SwiftUI

// MARK: - Search overlay panel

final class SearchOverlayWindow: NSPanel {
    private var hostingView: NSHostingView<SearchOverlayView>?

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless],   // activating panel — must be key to accept typing
            backing: .buffered,
            defer: false
        )
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false   // SwiftUI draws its own shadow
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    func show() {
        let screen = NSScreen.main?.visibleFrame
                  ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let w: CGFloat = 540
        let h: CGFloat = 440   // search field + up to 7 result rows
        let x = screen.midX - w / 2
        let y = screen.midY - h / 2 + 60   // slightly above centre feels more natural

        let view = SearchOverlayView()
        if let hv = hostingView {
            hv.rootView = view
        } else {
            let hv = NSHostingView(rootView: view)
            contentView = hv
            hostingView = hv
        }

        setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hide() {
        orderOut(nil)
    }
}

// MARK: - Search overlay SwiftUI view

private struct SearchOverlayView: View {
    @ObservedObject private var manager = ClipboardManager.shared
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // ── Search field ──────────────────────────────────────────
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.secondary)

                TextField("Search clipboard…", text: $manager.searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .focused($fieldFocused)
                    .onSubmit { manager.commitSearchPaste() }

                if !manager.searchQuery.isEmpty {
                    Button {
                        manager.searchQuery = ""
                        manager.searchSelectedIndex = 0
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity)
                }

                Text("Esc")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary.opacity(0.6))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 4))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            Divider()

            // ── Results / hints ───────────────────────────────────────
            Group {
                if manager.searchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                    // Empty-state hint
                    VStack(spacing: 8) {
                        Image(systemName: "sparkle.magnifyingglass")
                            .font(.system(size: 28))
                            .foregroundColor(.secondary.opacity(0.4))
                        Text("Type to search clipboard history")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                        Text("Semantic search — find items by meaning, not just exact text")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary.opacity(0.6))
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
                } else if manager.searchResults.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 24))
                            .foregroundColor(.secondary.opacity(0.3))
                        Text("No results for \"\(manager.searchQuery)\"")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(Array(manager.searchResults.enumerated()), id: \.element.id) { idx, item in
                                SearchResultRow(item: item, isSelected: idx == manager.searchSelectedIndex)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        manager.searchSelectedIndex = idx
                                        manager.commitSearchPaste()
                                    }
                                    .onHover { hovering in
                                        if hovering { manager.searchSelectedIndex = idx }
                                    }
                                if idx < manager.searchResults.count - 1 {
                                    Divider().padding(.leading, 44)
                                }
                            }
                        }
                    }
                }
            }

            // ── Footer hint ───────────────────────────────────────────
            if !manager.searchResults.isEmpty {
                Divider()
                HStack(spacing: 12) {
                    Label("Navigate", systemImage: "arrow.up.arrow.down")
                    Label("Paste", systemImage: "return")
                    Spacer()
                    Text("\(manager.searchResults.count) result\(manager.searchResults.count == 1 ? "" : "s")")
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary.opacity(0.7))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
            }
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .stroke(Color.primary.opacity(0.1), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 28, x: 0, y: 14)
        .onAppear { fieldFocused = true }
        .onKeyPress(.escape)    { manager.closeSearch();      return .handled }
        .onKeyPress(.downArrow) { manager.searchSelectNext(); return .handled }
        .onKeyPress(.upArrow)   { manager.searchSelectPrev(); return .handled }
        .animation(.easeInOut(duration: 0.15), value: manager.searchResults.count)
    }
}

// MARK: - Individual result row

private struct SearchResultRow: View {
    let item: ClipboardItem
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            // Content-type icon
            Image(systemName: item.iconName)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(isSelected ? .accentColor : .secondary)
                .frame(width: 22, alignment: .center)

            // Preview + tags
            VStack(alignment: .leading, spacing: 3) {
                Text(previewLine)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .foregroundColor(.primary)

                HStack(spacing: 6) {
                    ItemTagStrip(tags: item.tags, maxVisible: 3, compact: true)
                    if let meta = item.metadataSummary {
                        Text(meta)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Text(item.relativeTimestamp)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }

            // Return indicator when selected
            if isSelected {
                Image(systemName: "return")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(isSelected
                    ? Color.accentColor.opacity(0.12)
                    : Color.clear)
    }

    private var previewLine: String {
        switch item.content {
        case .image:
            if let title = item.urlTitle { return title }
            if let meta  = item.metadataSummary { return "Image — \(meta)" }
            return "[Image]"
        case .file(let url):   return url.lastPathComponent
        case .files(let urls): return "\(urls.count) files — \(urls.map(\.lastPathComponent).prefix(3).joined(separator: ", "))"
        default:               return item.previewText
        }
    }
}
