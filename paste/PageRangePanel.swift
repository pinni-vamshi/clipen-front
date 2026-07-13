import AppKit
import Combine
import SwiftUI
@preconcurrency import PDFKit

struct InlinePagePicker: View {
    @ObservedObject private var manager = ClipboardManager.shared

    var body: some View {
        VStack(spacing: 0) {
            queryRow
            Divider()
            grid
            Divider()
            selectionCountRow
        }
    }

    private var queryRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "textformat.123")
                .font(.system(size: 11))
                .foregroundColor(.accentColor)
            HStack(spacing: 0) {
                if manager.pageRangeQuery.isEmpty {
                    BlinkingCursor()
                        .foregroundColor(.accentColor)
                    Text("Type e.g. 1-3, 5, 7-9")
                        .foregroundColor(.secondary.opacity(0.55))
                } else {
                    Text(manager.pageRangeQuery)
                        .foregroundColor(.primary)
                    BlinkingCursor()
                        .foregroundColor(.accentColor)
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 12, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
            .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.accentColor.opacity(0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.accentColor.opacity(0.4), lineWidth: 1)
        )
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var grid: some View {
        let pageCount = manager.pageRangePageCount
        let effective = manager.pageRangeEffectiveSelection
        return ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 6), spacing: 5) {
                ForEach(0..<pageCount, id: \.self) { idx in
                    let isOn = effective.contains(idx)
                    Button {
                        manager.togglePageRangeManualPage(idx)
                    } label: {
                        Text("\(idx + 1)")
                            .font(.system(size: 11, weight: isOn ? .semibold : .regular, design: .monospaced))
                            .foregroundColor(isOn ? .white : .primary)
                            .frame(maxWidth: .infinity, minHeight: 26)
                            .background(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(isOn ? Color.accentColor : Color.primary.opacity(0.06))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .stroke(isOn ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var selectionCountRow: some View {
        let count = manager.pageRangeEffectiveSelection.count
        return HStack {
            Text(count == 0 ? "No pages selected"
                            : (count == 1 ? "1 page selected" : "\(count) pages selected"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(count == 0 ? .secondary : .accentColor)
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

struct InlineLanguagePicker: View {
    @ObservedObject private var manager = ClipboardManager.shared

    var body: some View {
        VStack(spacing: 0) {
            queryRow
            Divider()
            list
        }
    }

    private var queryRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundColor(.accentColor)
            HStack(spacing: 0) {
                if manager.languagePickerQuery.isEmpty {
                    BlinkingCursor()
                        .foregroundColor(.accentColor)
                    Text("Type to search a language…")
                        .foregroundColor(.secondary.opacity(0.55))
                } else {
                    Text(manager.languagePickerQuery)
                        .foregroundColor(.primary)
                    BlinkingCursor()
                        .foregroundColor(.accentColor)
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 12, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
            .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.accentColor.opacity(0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.accentColor.opacity(0.4), lineWidth: 1)
        )
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var list: some View {
        let languages = manager.languagePickerFilteredLanguages
        return ScrollViewReader { proxy in
            ScrollView {
                if languages.isEmpty {
                    Text("No matching language")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .padding(.vertical, 14)
                } else {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(languages.enumerated()), id: \.element.code) { idx, lang in
                            let isSelected = idx == manager.languagePickerSelectedIndex
                            Button {
                                manager.languagePickerSelectedIndex = idx
                                manager.commitLanguagePickerTranslation()
                            } label: {
                                HStack {
                                    Text(lang.name)
                                        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                                        .foregroundColor(isSelected ? .white : .primary)
                                    Spacer()
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .frame(maxWidth: .infinity)
                                .background(
                                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                                        .fill(isSelected ? Color.accentColor : Color.clear)
                                )
                            }
                            .buttonStyle(.plain)
                            .id(idx)
                        }
                    }
                    .padding(8)
                }
            }
            .frame(maxHeight: 200)
            .onChange(of: manager.languagePickerSelectedIndex) { _, newIdx in
                withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(newIdx, anchor: .center) }
            }
        }
    }
}

struct BlinkingCursor: View {
    var period: Double = 0.5

    @State private var visible: Bool = true
    @State private var timer: Timer? = nil

    var body: some View {
        Text("▌")
            .opacity(visible ? 1 : 0)
            .frame(minWidth: 6, alignment: .leading)
            .onAppear {
                timer?.invalidate()
                timer = Timer.scheduledTimer(withTimeInterval: period, repeats: true) { _ in
                    visible.toggle()
                }
                if let t = timer { RunLoop.main.add(t, forMode: .common) }
            }
            .onDisappear {
                timer?.invalidate()
                timer = nil
            }
    }
}

enum PageRangeParser {
    static func parse(_ text: String, maxPage: Int) -> Set<Int> {
        guard !text.isEmpty, maxPage > 0 else { return [] }
        var result: Set<Int> = []
        for part in text.split(separator: ",") {
            let token = part.trimmingCharacters(in: .whitespaces)
            if token.isEmpty { continue }
            if let dashIdx = token.firstIndex(of: "-") {
                let lhs = token[..<dashIdx].trimmingCharacters(in: .whitespaces)
                let rhs = token[token.index(after: dashIdx)...].trimmingCharacters(in: .whitespaces)
                guard let a = Int(lhs), let b = Int(rhs) else { continue }
                let lo = max(1, min(a, b))
                let hi = min(maxPage, max(a, b))
                guard lo <= hi else { continue }
                for p in lo...hi { result.insert(p - 1) }
            } else if let single = Int(token) {
                if single >= 1 && single <= maxPage { result.insert(single - 1) }
            }
        }
        return result
    }
}
