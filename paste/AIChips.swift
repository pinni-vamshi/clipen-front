import Foundation
import Combine
import NaturalLanguage

struct AIFactChip: Identifiable, Equatable {
    let id: String
    let itemID: UUID
    let key: String
    let value: String
    let score: Float
}

@MainActor
final class AIFactIndex: ObservableObject {
    static let shared = AIFactIndex()

    static let scoreFloor: Float = 0.40

    static let maxChips = 10

    private static let chipHiddenKeys: Set<String> = ["description"]

    private static let maxChipDisplayLength = 30

    private struct Pair {
        let key: String
        let value: String
        let haystack: String
        var vec: [Float]?
        var keyVec: [Float]?
    }

    private struct Entry {
        let jsonHash: Int
        var pairs: [Pair]
        var vectorsReady: Bool
    }

    private var cache: [UUID: Entry] = [:]
    private var prewarming: Set<UUID> = []

    private static let embedQueue = DispatchQueue(label: "com.clipen.aifacts.embed", qos: .utility)

    @Published private(set) var generation: Int = 0

    private init() {}

    func chips(query: String, items: [ClipboardItem]) -> [AIFactChip] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { return [] }

        let qNorm = ClipboardItem.normalize(q)
        let tokens = ClipboardManager.queryTokens(qNorm)
        let firstToken = tokens.first
        let queryVec: [Float]? = AuthManager.shared.semanticSearch
            ? ClipenEmbedder.shared.vector(for: qNorm) : nil

        var scored: [AIFactChip] = []
        for item in items {
            ensureCached(item)
            guard let entry = cache[item.id] else { continue }
            if !entry.vectorsReady { prewarm(item.id) }

            for (i, pair) in entry.pairs.enumerated() {

                guard !Self.chipHiddenKeys.contains(pair.key.lowercased()) else { continue }
                guard pair.value.count <= Self.maxChipDisplayLength else { continue }

                let lex = ClipboardManager.score(text: pair.haystack, query: qNorm,
                                                 tokens: tokens, firstToken: firstToken)

                let fuzzyKey = Self.fuzzyKeyScore(key: pair.key, queryTokens: tokens)
                let lexOrFuzzy = max(lex, fuzzyKey)

                let sem = max(Self.pairSemantic(queryVec, pair.vec),
                              Self.pairSemantic(queryVec, pair.keyVec))
                let combined = 0.60 * lexOrFuzzy + 0.40 * sem
                guard combined >= Self.scoreFloor else { continue }
                scored.append(AIFactChip(id: "\(item.id)#\(i)", itemID: item.id,
                                         key: pair.key, value: pair.value, score: combined))
            }
        }

        scored.sort { $0.score > $1.score }
        var seen = Set<String>()
        var out: [AIFactChip] = []
        for chip in scored {
            let norm = ClipboardItem.normalize(chip.value)
            guard seen.insert(norm).inserted else { continue }
            out.append(chip)
            if out.count >= Self.maxChips { break }
        }
        return out
    }

    private static func pairSemantic(_ q: [Float]?, _ v: [Float]?) -> Float {
        guard let q, let v else { return 0 }
        let cos = ClipboardManager.cosineSimilarity(q, v)
        return max(0, min(1, (cos - 0.32) / 0.38))
    }

    private static func fuzzyKeyScore(key: String, queryTokens: [String]) -> Float {
        guard !queryTokens.isEmpty else { return 0 }
        let keyWords = keyWords(key)
        guard !keyWords.isEmpty else { return 0 }
        var best: Float = 0
        for qt in queryTokens {
            for kw in keyWords {
                best = max(best, fuzzyRatio(qt, kw))
            }
        }
        return best >= 0.7 ? best : 0
    }

    private static func keyWords(_ key: String) -> [String] {
        var spaced = ""
        for ch in key {
            if ch.isUppercase, !spaced.isEmpty, spaced.last?.isUppercase == false {
                spaced += " "
            }
            spaced.append(ch)
        }
        return spaced.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 3 }
    }

    private static func fuzzyRatio(_ a: String, _ b: String) -> Float {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        let maxLen = max(a.count, b.count)
        guard maxLen > 0 else { return 0 }
        return 1 - Float(levenshteinDistance(a, b)) / Float(maxLen)
    }

    private static func levenshteinDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var curr = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            curr[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                curr[j] = min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
            }
            prev = curr
        }
        return prev[b.count]
    }

    func reset() {
        cache.removeAll()
        prewarming.removeAll()
        generation &+= 1
    }

    private func ensureCached(_ item: ClipboardItem) {
        guard let json = item.aiStructuredText, !json.isEmpty else {
            cache[item.id] = nil
            return
        }
        let hash = json.hashValue
        if let existing = cache[item.id], existing.jsonHash == hash { return }
        let pairs = Self.flatten(json).map {
            Pair(key: $0.key, value: $0.value,
                 haystack: ClipboardItem.normalize("\($0.key) \($0.value)"), vec: nil, keyVec: nil)
        }
        cache[item.id] = Entry(jsonHash: hash, pairs: pairs, vectorsReady: pairs.isEmpty)
    }

    private func prewarm(_ id: UUID) {
        guard !prewarming.contains(id), let entry = cache[id], !entry.vectorsReady else { return }
        prewarming.insert(id)

        let texts = entry.pairs.map { "\($0.key): \($0.value)" }
        let keyTexts = entry.pairs.map { $0.key }

        Self.embedQueue.async {
            let vecs = texts.map { ClipenEmbedder.shared.vector(for: ClipboardItem.normalize($0)) }
            let keyVecs = keyTexts.map { ClipenEmbedder.shared.vector(for: ClipboardItem.normalize($0)) }
            Task { @MainActor in
                guard var e = AIFactIndex.shared.cache[id], e.pairs.count == vecs.count else {
                    AIFactIndex.shared.prewarming.remove(id); return
                }
                for i in e.pairs.indices {
                    e.pairs[i].vec = vecs[i]
                    if i < keyVecs.count { e.pairs[i].keyVec = keyVecs[i] }
                }
                e.vectorsReady = true
                AIFactIndex.shared.cache[id] = e
                AIFactIndex.shared.prewarming.remove(id)
                AIFactIndex.shared.generation &+= 1

                ClipboardManager.shared.refreshPopupFactChips()
            }
        }
    }

    private static let skippedKeys: Set<String> = ["keywords"]
    private static let maxValueLength = 120

    static func flatten(_ json: String) -> [(key: String, value: String)] {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else { return [] }
        var out: [(key: String, value: String)] = []
        walk(obj, path: [], into: &out)
        return out
    }

    private static func walk(_ node: Any, path: [String], into out: inout [(key: String, value: String)]) {
        switch node {
        case let dict as [String: Any]:
            for (k, v) in dict {
                guard !skippedKeys.contains(k.lowercased()) else { continue }
                walk(v, path: path + [k], into: &out)
            }
        case let arr as [Any]:

            let scalars = arr.compactMap { scalarString($0) }
            if scalars.count == arr.count, !arr.isEmpty {
                append(path: path, value: scalars.joined(separator: ", "), into: &out)
            } else {

                for (i, v) in arr.enumerated() {
                    walk(v, path: path + ["\(i + 1)"], into: &out)
                }
            }
        default:
            if let s = scalarString(node) { append(path: path, value: s, into: &out) }
        }
    }

    static func groupedFlatten(_ json: String) -> [DetailUnit.Kind] {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else { return [] }
        var out: [DetailUnit.Kind] = []
        walkGrouped(obj, path: [], into: &out)
        return out
    }

    private static func walkGrouped(_ node: Any, path: [String], into out: inout [DetailUnit.Kind]) {
        switch node {
        case let dict as [String: Any]:
            let entries = dict.filter { !skippedKeys.contains($0.key.lowercased()) }
            if !path.isEmpty, !entries.isEmpty, entries.allSatisfy({ isScalarLike($0.value) }) {
                var fields: [DetailField] = []
                for (k, v) in entries {
                    if let s = scalarString(v) {
                        let vv = s.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !vv.isEmpty, vv.count <= maxValueLength else { continue }
                        fields.append(DetailField(key: k.replacingOccurrences(of: "_", with: " "), value: vv))
                    } else if let arr = v as? [Any] {
                        let scalars = arr.compactMap { scalarString($0) }
                        guard scalars.count == arr.count, !arr.isEmpty else { continue }
                        fields.append(DetailField(key: k.replacingOccurrences(of: "_", with: " "),
                                                   value: scalars.joined(separator: ", ")))
                    }
                }
                guard !fields.isEmpty else { return }
                let groupKey = path.joined(separator: ".").replacingOccurrences(of: "_", with: " ")
                out.append(.group(key: groupKey, fields: fields))
            } else {
                for (k, v) in entries { walkGrouped(v, path: path + [k], into: &out) }
            }
        case let arr as [Any]:
            let scalars = arr.compactMap { scalarString($0) }
            if scalars.count == arr.count, !arr.isEmpty {
                appendSingle(path: path, value: scalars.joined(separator: ", "), into: &out)
            } else {
                for (i, v) in arr.enumerated() { walkGrouped(v, path: path + ["\(i + 1)"], into: &out) }
            }
        default:
            if let s = scalarString(node) { appendSingle(path: path, value: s, into: &out) }
        }
    }

    private static func isScalarLike(_ v: Any) -> Bool {
        if scalarString(v) != nil { return true }
        if let arr = v as? [Any] { return !arr.isEmpty && arr.allSatisfy { scalarString($0) != nil } }
        return false
    }

    private static func appendSingle(path: [String], value: String, into out: inout [DetailUnit.Kind]) {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty, v.count <= maxValueLength, !path.isEmpty else { return }
        let key = path.joined(separator: ".").replacingOccurrences(of: "_", with: " ")
        out.append(.single(DetailField(key: key, value: v)))
    }

    private static func scalarString(_ node: Any) -> String? {
        switch node {
        case let s as String: return s
        case let n as NSNumber:

            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
            return n.stringValue
        default: return nil
        }
    }

    private static func append(path: [String], value: String, into out: inout [(key: String, value: String)]) {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty, v.count <= maxValueLength, !path.isEmpty else { return }

        let key = path.joined(separator: ".").replacingOccurrences(of: "_", with: " ")
        out.append((key: key, value: v))
    }
}

import SwiftUI

struct AIFactChipView: View {
    let chip: AIFactChip
    var onSelect: () -> Void

    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        HStack(spacing: 7) {
            VStack(alignment: .leading, spacing: 0) {
                Text(chip.key.uppercased())
                    .font(.system(size: 7, weight: .semibold))
                    .tracking(0.6)
                    .foregroundColor(.secondary.opacity(0.7))
                Text(chip.value)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)
            }
            Button {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(chip.value, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(copied ? .green : .secondary)
            }
            .buttonStyle(.plain)
            .help("Copy \"\(chip.value)\"")
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.10 : 0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.10), lineWidth: 1)
        )
        .fixedSize(horizontal: true, vertical: false)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { onSelect() }
    }
}
