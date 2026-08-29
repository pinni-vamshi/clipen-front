import SwiftUI

/// Visual inspector for the AI-JSON embeddings: draws items and their
/// individual analyzed fields as a similarity network so retrieval quality
/// can be eyeballed directly (do items that "should" relate actually end up
/// close together?) instead of only trusted blind. Opened from Settings —
/// see `ClipenSettingsView.aiStructuringSection`.
struct SemanticNetworkView: View {
    @ObservedObject private var manager = ClipboardManager.shared
    @StateObject private var model = SemanticNetworkModel()

    @State private var tier: SemanticNode.Tier = .item
    /// "1 means exact" per the design this screen implements: the slider is
    /// a similarity threshold, not a fixed neighbor count, so a node's edge
    /// count is however many things are actually that similar — not forced
    /// to some fixed k.
    @State private var threshold: Float = 0.62
    @State private var maxEdgesPerNode: Int = 6
    @State private var selectedNode: SemanticNode? = nil

    private var currentEdges: [SemanticEdge] {
        model.edges(for: tier, threshold: threshold, maxPerNode: maxEdgesPerNode)
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                controls
                Divider().background(Color.border)
                ZStack {
                    Color.bg
                    if model.isBuilding {
                        buildingOverlay
                    } else if model.nodes(for: tier).isEmpty {
                        emptyState
                    } else {
                        GeometryReader { geo in
                            NetworkCanvas(
                                nodes: model.nodes(for: tier),
                                layout: model.layout(for: tier),
                                edges: currentEdges,
                                threshold: threshold,
                                canvasSize: geo.size,
                                selectedNode: $selectedNode
                            )
                        }
                    }
                }
            }
            .frame(minWidth: 560, minHeight: 480)

            Divider().background(Color.border)

            categoriesSidebar
                .frame(width: 260)
        }
        .background(Color.bg)
        .onAppear { if model.itemNodes.isEmpty { model.build(from: manager.items) } }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Picker("", selection: $tier) {
                    Text("Items").tag(SemanticNode.Tier.item)
                    Text("Fields").tag(SemanticNode.Tier.field)
                }
                .pickerStyle(.segmented)
                .frame(width: 160)

                Spacer()

                Button {
                    model.build(from: manager.items)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise").font(.system(size: 9, weight: .bold))
                        Text("Rebuild").font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundColor(.accent)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.accentDim, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(model.isBuilding)
            }

            HStack(spacing: 8) {
                Text("Similarity").font(.system(size: 11, weight: .semibold)).foregroundColor(.textDim)
                    .frame(width: 68, alignment: .leading)
                Slider(value: $threshold, in: SemanticNetworkModel.candidateFloor...0.98)
                Text(String(format: "%.2f", threshold))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(.textPri)
                    .frame(width: 40, alignment: .trailing)
            }

            HStack(spacing: 8) {
                Text("Max edges").font(.system(size: 11, weight: .semibold)).foregroundColor(.textDim)
                    .frame(width: 68, alignment: .leading)
                Stepper(value: $maxEdgesPerNode, in: 1...20) {
                    Text("\(maxEdgesPerNode) per node")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(.textPri)
                }
                Spacer()
                if let sel = selectedNode {
                    Text(sel.label)
                        .font(.system(size: 11))
                        .foregroundColor(.textSec)
                        .lineLimit(1)
                        .frame(maxWidth: 220, alignment: .trailing)
                }
            }
        }
        .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 10)
    }

    private var buildingOverlay: some View {
        VStack(spacing: 10) {
            ProgressView(value: model.buildProgress).frame(width: 200)
            Text("Building network…")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.textDim)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "circle.hexagongrid")
                .font(.system(size: 26, weight: .thin))
                .foregroundColor(.textDim.opacity(0.5))
            Text("No AI-analyzed items yet")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.textDim)
        }
    }

    private var categoriesSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("PATTERNS")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundColor(.textDim)
                    .tracking(0.6)
                Spacer()
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 8)

            Divider().background(Color.border)

            let groups = model.components(for: tier, edges: currentEdges)
            if groups.isEmpty {
                Text("No clusters at this similarity level — lower the slider.")
                    .font(.system(size: 11))
                    .foregroundColor(.textDim)
                    .padding(14)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                            patternRow(group)
                            Divider().background(Color.border).padding(.leading, 14)
                        }
                    }
                }
            }
        }
        .background(Color.surface)
    }

    private func patternRow(_ group: [SemanticNode]) -> some View {
        let dominantCategory = Dictionary(grouping: group, by: \.category)
            .max { $0.value.count < $1.value.count }?.key ?? "mixed"
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(NetworkCanvas.color(for: dominantCategory)).frame(width: 8, height: 8)
                Text(dominantCategory.capitalized)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.textPri)
                Spacer()
                Text("\(group.count)")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.textDim)
            }
            Text(group.prefix(3).map(\.label).joined(separator: " · "))
                .font(.system(size: 10))
                .foregroundColor(.textDim)
                .lineLimit(2)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            selectedNode = group.first
        }
    }
}

/// Renders the current tier's nodes/edges into a fixed layout space, scaled
/// to whatever frame SwiftUI actually gave it. Edge opacity scales with
/// similarity so the strongest connections read visually stronger, not just
/// numerically higher.
private struct NetworkCanvas: View {
    let nodes: [SemanticNode]
    let layout: [String: CGPoint]
    let edges: [SemanticEdge]
    let threshold: Float
    let canvasSize: CGSize
    @Binding var selectedNode: SemanticNode?

    private var scale: CGSize {
        CGSize(width: canvasSize.width / SemanticNetworkModel.layoutCanvasSize.width,
               height: canvasSize.height / SemanticNetworkModel.layoutCanvasSize.height)
    }

    private func scaledPoint(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x * scale.width, y: p.y * scale.height)
    }

    var body: some View {
        Canvas { context, _ in
            for edge in edges {
                guard let pa = layout[edge.a], let pb = layout[edge.b] else { continue }
                var path = Path()
                path.move(to: scaledPoint(pa))
                path.addLine(to: scaledPoint(pb))
                let t = max(0, min(1, (edge.similarity - threshold) / max(0.001, 1 - threshold)))
                context.stroke(path, with: .color(Color.accent.opacity(0.08 + 0.35 * Double(t))), lineWidth: 1)
            }
            for node in nodes {
                guard let p = layout[node.id] else { continue }
                let sp = scaledPoint(p)
                let isSelected = selectedNode?.id == node.id
                let radius: CGFloat = node.tier == .item ? 5 : 3.5
                let rect = CGRect(x: sp.x - radius, y: sp.y - radius, width: radius * 2, height: radius * 2)
                context.fill(Path(ellipseIn: rect), with: .color(Self.color(for: node.category)))
                if isSelected {
                    context.stroke(Path(ellipseIn: rect.insetBy(dx: -3, dy: -3)),
                                    with: .color(.white), lineWidth: 1.5)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { location in
            selectedNode = nearestNode(to: location)
        }
    }

    private func nearestNode(to location: CGPoint) -> SemanticNode? {
        var best: (node: SemanticNode, dist: CGFloat)? = nil
        for node in nodes {
            guard let p = layout[node.id] else { continue }
            let sp = scaledPoint(p)
            let dx = sp.x - location.x, dy = sp.y - location.y
            let dist = sqrt(dx * dx + dy * dy)
            if best == nil || dist < best!.dist { best = (node, dist) }
        }
        guard let best, best.dist < 24 else { return nil }
        return best.node
    }

    /// Deterministic hash-to-hue so the same category always renders the
    /// same color across rebuilds, without maintaining an explicit palette
    /// map for however many distinct tags/field-keys show up.
    static func color(for category: String) -> Color {
        var hash: UInt64 = 5381
        for byte in category.utf8 { hash = ((hash << 5) &+ hash) &+ UInt64(byte) }
        let hue = Double(hash % 360) / 360.0
        return Color(hue: hue, saturation: 0.55, brightness: 0.85)
    }
}
