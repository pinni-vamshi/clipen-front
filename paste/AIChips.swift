import Foundation
import Combine
import NaturalLanguage

/// One key/value fact lifted out of an item's AI-structured JSON, scored
/// against whatever the user typed.
struct AIFactChip: Identifiable, Equatable {
    let id: String        // itemID + keypath — stable across re-ranks
    let itemID: UUID
    let key: String       // display label, e.g. "organization"
    let value: String
    let score: Float
}

/// Ranks individual JSON key/value pairs against the search query so the
/// popup can surface the specific facts that explain a match, rather than
/// only whole items.
///
/// Scoring deliberately mirrors `hybridSearch`'s lexical+semantic blend
/// instead of inventing a second ranking system — if the chips ranked by
/// different rules than the results below them, the two would routinely
/// disagree about what's relevant, which reads as a bug.
///
/// Pure embedding matching was considered and rejected for the *primary*
/// signal: these pairs are 2-5 word fragments, and NLContextualEmbedding is
/// a sentence model whose output on fragments that short is dominated by
/// generic structure rather than meaning. That is the same noise that made
/// unrelated items score 0.3-0.5 against "university" before the floor was
/// raised. Literal matching stays the precise signal; embeddings add the
/// semantic leap ("university" -> "Lovely Professional University") on top.
@MainActor
final class AIFactIndex: ObservableObject {
    static let shared = AIFactIndex()

    /// Below this, a pair is noise. Without a hard floor the strip would
    /// always show *something* — "least bad" rather than "actually
    /// relevant" — which is exactly the failure mode the main search had.
    static let scoreFloor: Float = 0.40
    /// Horizontal scrolling stops being scannable past roughly this many.
    static let maxChips = 10

    private struct Pair {
        let key: String
        let value: String
        let haystack: String   // normalized "key value", what lexical scoring reads
        var vec: [Float]?      // embedding of "key: value"
        var keyVec: [Float]?   // embedding of the key alone
    }

    private struct Entry {
        let jsonHash: Int
        var pairs: [Pair]
        var vectorsReady: Bool
    }

    private var cache: [UUID: Entry] = [:]
    private var prewarming: Set<UUID> = []
    /// All fact-chip embedding work funnels through here, one job at a time.
    private static let embedQueue = DispatchQueue(label: "com.clipen.aifacts.embed", qos: .utility)

    /// Bumped when a background prewarm finishes, purely so SwiftUI
    /// re-renders the strip with the now-available semantic scores.
    @Published private(set) var generation: Int = 0

    private init() {}

    // MARK: - Query

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
                let lex = ClipboardManager.score(text: pair.haystack, query: qNorm,
                                                 tokens: tokens, firstToken: firstToken)
                // Compare against the KEY alone as well as the whole pair.
                // A query is often about the field name ("phone number",
                // "when does it expire") rather than the value, and blending
                // a value like "9032930998" into the vector drags it away
                // from the concept the key expresses. Taking the max means
                // either a value-shaped or a field-name-shaped query can win.
                let sem = max(Self.pairSemantic(queryVec, pair.vec),
                              Self.pairSemantic(queryVec, pair.keyVec))
                let combined = 0.60 * lex + 0.40 * sem
                guard combined >= Self.scoreFloor else { continue }
                scored.append(AIFactChip(id: "\(item.id)#\(i)", itemID: item.id,
                                         key: pair.key, value: pair.value, score: combined))
            }
        }

        // Highest first, then drop repeats of the same value — several items
        // legitimately share a value ("university"), and a strip of five
        // near-identical pills is worse than three distinct ones. The
        // best-ranked occurrence wins and the rest are dropped.
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

    /// Deliberately NOT `ClipboardManager.semanticComponent`.
    ///
    /// That one's 0.45 cosine floor was tuned for whole-item haystacks,
    /// which are long. These pairs are 2-5 word fragments whose cosine
    /// scores sit in a different, more compressed range, so reusing 0.45
    /// zeroed out the semantic signal almost everywhere and left chips
    /// running on literal matching alone. The combined 0.40 chip floor is
    /// what keeps noise out; this only decides how the raw cosine maps in.
    private static func pairSemantic(_ q: [Float]?, _ v: [Float]?) -> Float {
        guard let q, let v else { return 0 }
        let cos = ClipboardManager.cosineSimilarity(q, v)
        return max(0, min(1, (cos - 0.32) / 0.38))
    }

    /// Drops every cached pair and embedding. Used by Regenerate All —
    /// the chips are derived from the JSON, so stale chips would otherwise
    /// outlive the analysis they came from.
    func reset() {
        cache.removeAll()
        prewarming.removeAll()
        generation &+= 1
    }

    // MARK: - Cache

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

    /// Embeddings are computed off the main thread and only once per item.
    /// Until they land, that item's pairs score on literal matching alone —
    /// degraded but correct, never blocking the popup on model work.
    private func prewarm(_ id: UUID) {
        guard !prewarming.contains(id), let entry = cache[id], !entry.vectorsReady else { return }
        prewarming.insert(id)
        // Embed as a natural phrase ("organization: Lovely Professional
        // University"), never raw JSON — braces and quotes are pure noise
        // to a sentence embedding model.
        let texts = entry.pairs.map { "\($0.key): \($0.value)" }
        let keyTexts = entry.pairs.map { $0.key }
        // One shared serial queue, never a task per item. Prewarm runs for
        // every result of a search, so spawning a detached task each time
        // fanned out into many concurrent calls into the embedder at once —
        // and NLContextualEmbedding is not thread-safe, which segfaulted
        // inside CoreNLP. The embedder now locks internally too; this keeps
        // the work bounded instead of parking dozens of blocked threads.
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
                // Semantic scores just became available for this item — ask
                // for a re-rank rather than mutating anything a view reads.
                ClipboardManager.shared.refreshPopupFactChips()
            }
        }
    }

    // MARK: - JSON flattening

    /// `keywords` is deliberately dropped: it's the search-term scaffolding
    /// the prompt asks for, not a fact about the content, so it would fill
    /// the strip with the user's own query words echoed back.
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
            // An array of scalars reads better as one chip than as N chips
            // ("tags: a, b, c"); an array of objects still has to expand.
            let scalars = arr.compactMap { scalarString($0) }
            if scalars.count == arr.count, !arr.isEmpty {
                append(path: path, value: scalars.joined(separator: ", "), into: &out)
            } else {
                // Index the path. Without this, an array of objects — a
                // timetable's "schedule": [ {...}, {...} ] — collapses every
                // entry onto the SAME key ("schedule.day" five times over).
                // Identical key+value pairs then produce identical ids, and
                // SwiftUI's ForEach renders duplicate ids incorrectly: rows
                // highlight in the wrong place, several look selected at
                // once, or a selection vanishes entirely.
                for (i, v) in arr.enumerated() {
                    walk(v, path: path + ["\(i + 1)"], into: &out)
                }
            }
        default:
            if let s = scalarString(node) { append(path: path, value: s, into: &out) }
        }
    }

    private static func scalarString(_ node: Any) -> String? {
        switch node {
        case let s as String: return s
        case let n as NSNumber:
            // NSNumber bridges Bool too; render those as true/false, not 1/0.
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
            return n.stringValue
        default: return nil
        }
    }

    private static func append(path: [String], value: String, into out: inout [(key: String, value: String)]) {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty, v.count <= maxValueLength, !path.isEmpty else { return }
        // Nested keys keep their parent for context ("address.city"), which
        // matters when a bare "city" would be ambiguous across items.
        let key = path.joined(separator: ".").replacingOccurrences(of: "_", with: " ")
        out.append((key: key, value: v))
    }
}

import SwiftUI

/// A single fact pill: dim key label, prominent value, copy button.
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
