import Foundation
import CoreGraphics
import Combine

/// A node in the semantic-similarity network the "Semantic Network"
/// dashboard visualizes: either a whole item (using its `aiEmbedding`) or a
/// single flattened field from that item's AI JSON, embedded individually.
/// Two tiers on purpose — `aiEmbedding` blends a whole item's fields into
/// one vector (good for item-to-item search), which hides exactly the
/// finer "these items share this one field" pattern the field tier exists
/// to show.
struct SemanticNode: Identifiable, Hashable {
    enum Tier: String { case item, field }
    let id: String
    let itemID: UUID
    let tier: Tier
    let label: String
    let category: String
    let vector: [Float]

    static func == (lhs: SemanticNode, rhs: SemanticNode) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct SemanticEdge: Identifiable {
    var id: String { "\(a)~\(b)" }
    let a: String
    let b: String
    let similarity: Float
}

/// Builds the two-tier similarity network and lays it out once per tier.
/// This is a deliberately on-demand, in-memory analysis tool — not part of
/// the live search/paste path — so it recomputes from scratch each time
/// it's opened rather than persisting to disk or auto-updating in the
/// background the way `aiEmbedding` does.
@MainActor
final class SemanticNetworkModel: ObservableObject {
    @Published private(set) var itemNodes: [SemanticNode] = []
    @Published private(set) var fieldNodes: [SemanticNode] = []
    @Published private(set) var itemLayout: [String: CGPoint] = [:]
    @Published private(set) var fieldLayout: [String: CGPoint] = [:]
    @Published private(set) var isBuilding = false
    @Published private(set) var buildProgress: Double = 0
    @Published private(set) var skippedItemCount = 0

    /// Edges below this are never worth drawing even at the loosest slider
    /// setting, so they're dropped at build time instead of kept around and
    /// re-filtered on every slider tick.
    static let candidateFloor: Float = 0.3
    /// Cap on candidate edges kept per node — without this a very generic
    /// field ("yes", "N/A") would carry the same size candidate list as a
    /// genuinely distinctive one, for no visual benefit.
    private static let maxCandidatesPerNode = 40
    /// Layout and the O(n²) similarity pass both scale quadratically; past
    /// this many nodes a tier stops being interactively redrawable, so the
    /// field tier (which can run into the thousands) is capped to its
    /// most-recently-analyzed items rather than silently hanging the UI.
    static let maxNodesPerTier = 400
    /// Fixed nominal size the layout is computed in; the view scales this
    /// to fit whatever frame it actually has, so layout never needs to be
    /// recomputed on window resize.
    static let layoutCanvasSize = CGSize(width: 900, height: 700)

    private var itemCandidates: [String: [SemanticEdge]] = [:]
    private var fieldCandidates: [String: [SemanticEdge]] = [:]

    func nodes(for tier: SemanticNode.Tier) -> [SemanticNode] {
        tier == .item ? itemNodes : fieldNodes
    }

    func layout(for tier: SemanticNode.Tier) -> [String: CGPoint] {
        tier == .item ? itemLayout : fieldLayout
    }

    /// Filters the precomputed candidate edges by the current threshold and
    /// per-node cap. Cheap — safe to call on every slider tick since the
    /// expensive O(n²) similarity pass already happened in `build`.
    func edges(for tier: SemanticNode.Tier, threshold: Float, maxPerNode: Int) -> [SemanticEdge] {
        let candidates = tier == .item ? itemCandidates : fieldCandidates
        var seen = Set<String>()
        var result: [SemanticEdge] = []
        for (_, list) in candidates {
            for edge in list.prefix(maxPerNode) where edge.similarity >= threshold {
                guard !seen.contains(edge.id) else { continue }
                seen.insert(edge.id)
                result.append(edge)
            }
        }
        return result
    }

    /// Connected components of the currently filtered graph — the
    /// "categories" the dashboard's pattern list shows. Plain union-find
    /// over the visible edges, not a real community-detection algorithm:
    /// sufficient for "which items ended up linked together at this
    /// threshold," which is what the dashboard is actually asking.
    func components(for tier: SemanticNode.Tier, edges: [SemanticEdge]) -> [[SemanticNode]] {
        let all = nodes(for: tier)
        var parent: [String: String] = [:]
        for n in all { parent[n.id] = n.id }
        func find(_ x: String) -> String {
            var x = x
            while parent[x] != x { x = parent[x] ?? x }
            return x
        }
        func union(_ a: String, _ b: String) {
            let ra = find(a), rb = find(b)
            guard ra != rb else { return }
            parent[ra] = rb
        }
        for e in edges { union(e.a, e.b) }
        var groups: [String: [SemanticNode]] = [:]
        for n in all { groups[find(n.id), default: []].append(n) }
        return groups.values
            .filter { $0.count > 1 }
            .sorted { $0.count > $1.count }
    }

    /// Plain-data snapshot of whatever `item.content`/`item.aiStructuredText`
    /// this build needs, taken on the main actor before hopping to the
    /// background queue — `ClipboardContent.plainText` and friends are
    /// main-actor isolated, so nothing that touches them can run inside the
    /// background closure below.
    private struct ItemSnapshot {
        let id: UUID
        let label: String
        let category: String
        let aiEmbedding: [Float]?
        let flattenedFields: [(key: String, value: String)]
    }

    func build(from items: [ClipboardItem]) {
        guard !isBuilding else { return }
        isBuilding = true
        buildProgress = 0
        let analyzed = items.filter { $0.aiStructuredText?.isEmpty == false }
        let itemSlice = Array(analyzed.prefix(Self.maxNodesPerTier))
        skippedItemCount = analyzed.count - itemSlice.count

        let snapshots: [ItemSnapshot] = itemSlice.map { item in
            let pairs = item.aiStructuredText.map { AIFactIndex.flatten($0) } ?? []
            return ItemSnapshot(id: item.id, label: Self.itemLabel(item),
                                 category: item.primaryTag.rawValue,
                                 aiEmbedding: item.aiEmbedding, flattenedFields: pairs)
        }

        // Matches the rest of this file's background-work pattern
        // (`recomputeEmbeddingsInBackground` etc.) — plain GCD, not
        // structured concurrency, so it isn't subject to the strict
        // actor-isolation checking a `Task` would trigger for a project
        // built with `-default-isolation=MainActor`.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            // Tier 1: items — reuses the existing `aiEmbedding`, no new
            // embedding calls needed here.
            let itemNodes: [SemanticNode] = snapshots.compactMap { snap in
                guard let vec = snap.aiEmbedding else { return nil }
                return SemanticNode(id: snap.id.uuidString, itemID: snap.id, tier: .item,
                                     label: snap.label, category: snap.category, vector: vec)
            }
            DispatchQueue.main.async { self.buildProgress = 0.15 }

            // Tier 2: individual fields — embedded one at a time here,
            // since nothing persists a per-field vector today.
            let totalFields = snapshots.reduce(0) { $0 + $1.flattenedFields.count }
            var processedFields = 0
            var fieldNodes: [SemanticNode] = []
            fieldNodes.reserveCapacity(min(totalFields, Self.maxNodesPerTier * 6))

            outer: for snap in snapshots {
                for pair in snap.flattenedFields {
                    guard fieldNodes.count < Self.maxNodesPerTier * 6 else { break outer }
                    let text = "\(pair.key): \(pair.value)"
                    if let vec = ClipenEmbedder.shared.vector(for: text) {
                        let nodeID = "\(snap.id.uuidString)#\(pair.key)"
                        let label = text.count > 40 ? String(text.prefix(40)) + "…" : text
                        fieldNodes.append(SemanticNode(id: nodeID, itemID: snap.id, tier: .field,
                                                        label: label, category: pair.key, vector: vec))
                    }
                    processedFields += 1
                    if processedFields % 25 == 0 {
                        let progress = 0.15 + (totalFields > 0 ? Double(processedFields) / Double(totalFields) : 1) * 0.55
                        DispatchQueue.main.async { self.buildProgress = progress }
                    }
                }
            }

            DispatchQueue.main.async { self.buildProgress = 0.7 }
            let itemCand = Self.candidateEdges(for: itemNodes)
            DispatchQueue.main.async { self.buildProgress = 0.8 }
            let fieldCand = Self.candidateEdges(for: fieldNodes)
            DispatchQueue.main.async { self.buildProgress = 0.88 }

            let itemLayout = GraphLayoutEngine.layout(
                nodeIDs: itemNodes.map(\.id),
                edges: itemCand.values.flatMap { $0 },
                canvasSize: Self.layoutCanvasSize)
            DispatchQueue.main.async { self.buildProgress = 0.94 }
            let fieldLayout = GraphLayoutEngine.layout(
                nodeIDs: fieldNodes.map(\.id),
                edges: fieldCand.values.flatMap { $0 },
                canvasSize: Self.layoutCanvasSize)

            DispatchQueue.main.async {
                self.itemNodes = itemNodes
                self.fieldNodes = fieldNodes
                self.itemCandidates = itemCand
                self.fieldCandidates = fieldCand
                self.itemLayout = itemLayout
                self.fieldLayout = fieldLayout
                self.buildProgress = 1
                self.isBuilding = false
            }
        }
    }

    nonisolated private static func candidateEdges(for nodes: [SemanticNode]) -> [String: [SemanticEdge]] {
        guard nodes.count > 1 else { return [:] }
        var byNode: [String: [SemanticEdge]] = [:]
        for i in nodes.indices {
            var row: [SemanticEdge] = []
            row.reserveCapacity(maxCandidatesPerNode)
            for j in nodes.indices where j != i {
                let sim = ClipboardManager.cosineSimilarity(nodes[i].vector, nodes[j].vector)
                guard sim >= candidateFloor else { continue }
                row.append(SemanticEdge(a: nodes[i].id, b: nodes[j].id, similarity: sim))
            }
            row.sort { $0.similarity > $1.similarity }
            if row.count > maxCandidatesPerNode { row.removeLast(row.count - maxCandidatesPerNode) }
            byNode[nodes[i].id] = row
        }
        return byNode
    }

    nonisolated private static func itemLabel(_ item: ClipboardItem) -> String {
        if let text = item.content.plainText, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return String(text.prefix(36))
        }
        return item.primaryTag.rawValue.capitalized
    }
}

/// A minimal Fruchterman-Reingold-style force-directed layout: nodes repel
/// each other, edges pull their endpoints together, both forces cool down
/// over the iteration count so the system settles instead of oscillating.
/// Computed once per tier build (not per slider tick) — see
/// `SemanticNetworkModel`'s doc comment for why positions stay fixed while
/// only edge visibility changes.
enum GraphLayoutEngine {
    static func layout(nodeIDs: [String], edges: [SemanticEdge], canvasSize: CGSize,
                        iterations: Int = 120) -> [String: CGPoint] {
        guard !nodeIDs.isEmpty else { return [:] }
        var pos: [String: CGPoint] = [:]
        let radius = min(canvasSize.width, canvasSize.height) * 0.35
        let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
        for (i, id) in nodeIDs.enumerated() {
            let angle = 2 * Double.pi * Double(i) / Double(max(nodeIDs.count, 1))
            pos[id] = CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
        }
        guard nodeIDs.count > 1 else { return pos }

        let area = Double(canvasSize.width * canvasSize.height)
        let k = sqrt(area / Double(nodeIDs.count))
        var temperature = Double(min(canvasSize.width, canvasSize.height)) * 0.05

        for _ in 0..<iterations {
            var disp: [String: CGVector] = [:]
            for i in 0..<nodeIDs.count {
                var dx = 0.0, dy = 0.0
                guard let pi = pos[nodeIDs[i]] else { continue }
                for j in 0..<nodeIDs.count where j != i {
                    guard let pj = pos[nodeIDs[j]] else { continue }
                    var vx = Double(pi.x - pj.x), vy = Double(pi.y - pj.y)
                    var dist = sqrt(vx * vx + vy * vy)
                    if dist < 0.01 {
                        dist = 0.01
                        vx = Double.random(in: -1...1); vy = Double.random(in: -1...1)
                    }
                    let force = (k * k) / dist
                    dx += (vx / dist) * force
                    dy += (vy / dist) * force
                }
                disp[nodeIDs[i]] = CGVector(dx: dx, dy: dy)
            }
            for e in edges {
                guard let pa = pos[e.a], let pb = pos[e.b] else { continue }
                var vx = Double(pa.x - pb.x), vy = Double(pa.y - pb.y)
                var dist = sqrt(vx * vx + vy * vy)
                if dist < 0.01 { dist = 0.01 }
                let force = (dist * dist) / k
                let fx = (vx / dist) * force, fy = (vy / dist) * force
                disp[e.a]?.dx -= fx; disp[e.a]?.dy -= fy
                disp[e.b]?.dx += fx; disp[e.b]?.dy += fy
            }
            for id in nodeIDs {
                guard var p = pos[id], let d = disp[id] else { continue }
                let len = sqrt(d.dx * d.dx + d.dy * d.dy)
                guard len > 0.01 else { continue }
                let clamped = min(len, temperature)
                p.x += CGFloat((d.dx / len) * clamped)
                p.y += CGFloat((d.dy / len) * clamped)
                p.x = min(max(p.x, 10), canvasSize.width - 10)
                p.y = min(max(p.y, 10), canvasSize.height - 10)
                pos[id] = p
            }
            temperature *= 0.95
        }
        return pos
    }
}
