import SwiftUI
import Grape
import ForceSimulation

/// Renders MiroFish's Zep knowledge graph as an interactive force-directed graph
/// using the Grape package. Nodes are coloured by entity type; tapping a node
/// reveals its details and relationships. Pan/zoom/drag are wired via Grape's
/// `graphOverlay` + `withGraphDragGesture`.
struct KnowledgeGraphView: View {
    let graph: ForecastGraph

    @State private var graphStates = ForceDirectedGraphState(
        initialIsRunning: true,
        initialModelTransform: .identity
    )
    @State private var selectedNodeID: String?
    @State private var showLabels = false

    // Precomputed lookups (cheap; graph is capped at ~140 nodes).
    private var nodeByID: [String: GraphVizNode] {
        Dictionary(graph.nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }
    private var degree: [String: Int] {
        var d: [String: Int] = [:]
        for e in graph.edges { d[e.source, default: 0] += 1; d[e.target, default: 0] += 1 }
        return d
    }

    var body: some View {
        if graph.isEmpty {
            emptyState
        } else {
            ZStack(alignment: .topLeading) {
                graphCanvas
                legend
                    .padding(12)
                if let id = selectedNodeID, let node = nodeByID[id] {
                    nodeInspector(node)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(12)
                        .allowsHitTesting(true)
                }
            }
            .background(graphBackground)
            .overlay(alignment: .top) { controlBar }
        }
    }

    // MARK: - Graph canvas

    private var graphCanvas: some View {
        let types = graph.entityTypes
        let deg = degree
        return ForceDirectedGraph(states: graphStates) {
            Series(graph.nodes) { node in
                NodeMark(id: node.id)
                    .symbol(.circle)
                    .symbolSize(radius: 5.0 + CGFloat(min(deg[node.id] ?? 0, 12)))
                    .foregroundStyle(GraphPalette.color(for: node.type, in: types))
                    .stroke(node.id == selectedNodeID ? .white : .white.opacity(0.35),
                            StrokeStyle(lineWidth: node.id == selectedNodeID ? 2.0 : 0.6))
                    .annotation(showLabels ? node.label : nil, alignment: .bottom, offset: .zero)
            }
            Series(graph.edges) { edge in
                LinkMark(from: edge.source, to: edge.target)
            }
            .stroke(Color.gray.opacity(0.35), StrokeStyle(lineWidth: 1.0, lineCap: .round))
        } force: {
            .manyBody(strength: -48)
            .center()
            .link(originalLength: 42.0, stiffness: .weightedByDegree { _, _ in 1.0 })
        } emittingNewNodesWithStates: { _ in
            KineticState(position: .zero)
        }
        .graphOverlay { proxy in
            Rectangle()
                .fill(.clear)
                .contentShape(Rectangle())
                .withGraphDragGesture(proxy, of: String.self)
                .onTapGesture { location in
                    let hit = proxy.node(of: String.self, at: location)
                    withAnimation(.easeInOut(duration: 0.15)) {
                        selectedNodeID = (hit == selectedNodeID) ? nil : hit
                    }
                }
        }
    }

    // MARK: - Controls

    private var controlBar: some View {
        HStack(spacing: 6) {
            Button { graphStates.isRunning.toggle() } label: {
                Image(systemName: graphStates.isRunning ? "pause.fill" : "play.fill")
            }
            .help(graphStates.isRunning ? "Pause layout" : "Resume layout")
            Divider().frame(height: 14)
            Button { graphStates.modelTransform.scaling(by: 1.15) } label: { Image(systemName: "plus.magnifyingglass") }
                .help("Zoom in")
            Button { graphStates.modelTransform.scaling(by: 0.87) } label: { Image(systemName: "minus.magnifyingglass") }
                .help("Zoom out")
            Button {
                withAnimation { graphStates.modelTransform = .identity }
            } label: { Image(systemName: "arrow.counterclockwise") }
                .help("Reset view")
            Divider().frame(height: 14)
            Toggle(isOn: $showLabels) { Image(systemName: "tag") }
                .toggleStyle(.button)
                .help("Show node labels")
        }
        .buttonStyle(.borderless)
        .labelStyle(.iconOnly)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.thinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.08)))
        .padding(.top, 10)
    }

    // MARK: - Legend

    private var legend: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.caption2)
                Text("\(graph.totalNodeCount) entities · \(graph.totalEdgeCount) relations")
                    .font(.caption2.weight(.medium))
            }
            .foregroundStyle(.secondary)
            ForEach(graph.entityTypes.prefix(10), id: \.self) { type in
                HStack(spacing: 6) {
                    Circle()
                        .fill(GraphPalette.color(for: type, in: graph.entityTypes))
                        .frame(width: 8, height: 8)
                    Text(type).font(.caption2)
                }
            }
            if graph.truncated {
                Text("Showing top \(graph.nodes.count) by connections")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.06)))
        .frame(maxWidth: 220, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Node inspector

    private func nodeInspector(_ node: GraphVizNode) -> some View {
        let connections = graph.edges.filter { $0.source == node.id || $0.target == node.id }
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle()
                    .fill(GraphPalette.color(for: node.type, in: graph.entityTypes))
                    .frame(width: 10, height: 10)
                Text(node.label).font(.headline).lineLimit(2)
                Spacer(minLength: 8)
                Button { withAnimation { selectedNodeID = nil } } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
            Text(node.type)
                .font(.caption.weight(.semibold))
                .foregroundStyle(GraphPalette.color(for: node.type, in: graph.entityTypes))
            if !node.summary.isEmpty {
                Text(node.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(5)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !connections.isEmpty {
                Divider()
                Text("\(connections.count) relationship\(connections.count == 1 ? "" : "s")")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(connections.prefix(8)) { edge in
                            let otherID = edge.source == node.id ? edge.target : edge.source
                            let other = nodeByID[otherID]?.label ?? String(otherID.prefix(8))
                            HStack(alignment: .top, spacing: 4) {
                                Image(systemName: edge.source == node.id ? "arrow.right" : "arrow.left")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                Text("\(edge.label.isEmpty ? "related to" : edge.label) · \(other)")
                                    .font(.caption2)
                                    .lineLimit(2)
                            }
                        }
                    }
                }
                .frame(maxHeight: 120)
            }
        }
        .padding(12)
        .frame(width: 280)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.08)))
        .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
    }

    // MARK: - States / chrome

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Knowledge graph pending", systemImage: "point.3.connected.trianglepath.dotted")
        } description: {
            Text("The temporal knowledge graph appears here once MiroFish finishes extracting entities into Zep.")
        }
    }

    @ViewBuilder
    private var graphBackground: some View {
        RoundedRectangle(cornerRadius: 14)
            .fill(Color(nsColor: .underPageBackgroundColor).opacity(0.5))
    }
}
