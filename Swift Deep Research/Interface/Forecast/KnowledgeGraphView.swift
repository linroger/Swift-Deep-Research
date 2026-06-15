import SwiftUI
import Grape
import ForceSimulation

/// Renders the backend's local Graphiti knowledge graph as an interactive force-directed graph
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

    /// Per-graph derived lookups, computed once whenever `graph` changes (see
    /// `.onChange(of: graph)`), not on every body pass. The 2s forecast poll
    /// re-runs body during the graph stage, so caching these avoids rebuilding
    /// degree/colour/adjacency maps continuously on the main thread.
    @State private var derived: GraphDerived

    init(graph: ForecastGraph) {
        self.graph = graph
        // Seed the cache from the initial graph so the first frame already has
        // correct colours/degrees (no one-frame gray flash before onAppear).
        _derived = State(initialValue: GraphDerived(graph))
    }

    /// Cached node/degree/colour/adjacency tables for the current graph.
    private struct GraphDerived {
        var nodeByID: [String: GraphVizNode] = [:]
        var degree: [String: Int] = [:]
        var colorByType: [String: Color] = [:]
        /// node id → edges incident on it (drives the inspector connection list).
        var edgesByNode: [String: [GraphVizEdge]] = [:]

        init(_ graph: ForecastGraph) {
            nodeByID = Dictionary(graph.nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for e in graph.edges {
                degree[e.source, default: 0] += 1
                degree[e.target, default: 0] += 1
                edgesByNode[e.source, default: []].append(e)
                // Skip the second append for a self-loop so an edge isn't listed
                // twice for the same node (matches the original per-edge filter
                // and keeps inspector ForEach ids unique).
                if e.target != e.source { edgesByNode[e.target, default: []].append(e) }
            }
            // Resolve the O(types) firstIndex palette lookup once per type here so
            // node symbols / legend / inspector can index a dictionary instead.
            for type in graph.entityTypes {
                colorByType[type] = GraphPalette.color(for: type, in: graph.entityTypes)
            }
        }
    }

    var body: some View {
        content
            // The cache is seeded in init for the first graph; rebuild it only
            // when the graph value actually changes, not on every body
            // re-evaluation from the 2s poll.
            .onChange(of: graph) { _, newGraph in derived = GraphDerived(newGraph) }
    }

    @ViewBuilder
    private var content: some View {
        if graph.isEmpty {
            emptyState
        } else {
            // GeometryReader hands the force-graph an explicit finite frame, so
            // Grape's greedy canvas can't impose a runaway size on its container.
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    graphBackground
                    graphCanvas
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                    legend
                        .padding(12)
                    // Inspector lives in an overlay (below) so it's always on top.
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .overlay(alignment: .top) { controlBar }
                .overlay(alignment: .bottomTrailing) {
                    if let id = selectedNodeID, let node = derived.nodeByID[id] {
                        nodeInspector(node)
                            .padding(12)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
        }
    }

    // MARK: - Graph canvas

    private var graphCanvas: some View {
        // Read the cached degree/colour tables (built once per graph change).
        let deg = derived.degree
        let colorByType = derived.colorByType
        return ForceDirectedGraph(states: graphStates) {
            Series(graph.nodes) { node in
                NodeMark(id: node.id)
                    .symbol(.circle)
                    // Grape's tap hit-area equals the drawn radius, so keep a
                    // generous floor — tiny nodes were nearly impossible to tap.
                    .symbolSize(radius: 8.0 + CGFloat(min(deg[node.id] ?? 0, 12)))
                    .foregroundStyle(colorByType[node.type] ?? .gray)
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
                // A simultaneous spatial tap survives the drag gesture (a plain
                // onTapGesture is swallowed by it) and carries the hit location.
                // Pad the hit test so taps near a small node still land.
                .simultaneousGesture(
                    SpatialTapGesture(coordinateSpace: .local)
                        .onEnded { value in
                            let hit = proxy.node(of: String.self, at: value.location)
                            withAnimation(.easeInOut(duration: 0.15)) {
                                if let hit { selectedNodeID = (hit == selectedNodeID) ? nil : hit }
                                else { selectedNodeID = nil }  // tap on empty space dismisses
                            }
                        }
                )
        }
    }

    // MARK: - Controls

    private var controlBar: some View {
        HStack(spacing: 6) {
            Button { graphStates.isRunning.toggle() } label: {
                Image(systemName: graphStates.isRunning ? "pause.fill" : "play.fill")
            }
            .help(graphStates.isRunning ? "Pause layout" : "Resume layout")
            .accessibilityLabel("Layout simulation")
            .accessibilityValue(graphStates.isRunning ? "Running" : "Paused")
            Divider().frame(height: 14)
            Button { graphStates.modelTransform.scaling(by: 1.15) } label: { Image(systemName: "plus.magnifyingglass") }
                .help("Zoom in")
                .accessibilityLabel("Zoom in")
            Button { graphStates.modelTransform.scaling(by: 0.87) } label: { Image(systemName: "minus.magnifyingglass") }
                .help("Zoom out")
                .accessibilityLabel("Zoom out")
            Button {
                withAnimation { graphStates.modelTransform = .identity }
            } label: { Image(systemName: "arrow.counterclockwise") }
                .help("Reset view")
                .accessibilityLabel("Reset view")
            Divider().frame(height: 14)
            Toggle(isOn: $showLabels) { Image(systemName: "tag") }
                .toggleStyle(.button)
                .help("Show node labels")
                .accessibilityLabel("Show node labels")
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
                        .fill(derived.colorByType[type] ?? .gray)
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
        // Use the precomputed adjacency map instead of filtering all edges per render.
        let connections = derived.edgesByNode[node.id] ?? []
        let nodeColor = derived.colorByType[node.type] ?? .gray
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle()
                    .fill(nodeColor)
                    .frame(width: 10, height: 10)
                Text(node.label).font(.headline).lineLimit(2)
                Spacer(minLength: 8)
                Button { withAnimation { selectedNodeID = nil } } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Close node details")
            }
            Text(node.type)
                .font(.caption.weight(.semibold))
                .foregroundStyle(nodeColor)
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
                            let other = derived.nodeByID[otherID]?.label ?? String(otherID.prefix(8))
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
            Text("The temporal knowledge graph appears here once the backend finishes extracting entities into the local Graphiti graph.")
        }
    }

    @ViewBuilder
    private var graphBackground: some View {
        RoundedRectangle(cornerRadius: 14)
            .fill(Color(nsColor: .underPageBackgroundColor).opacity(0.5))
    }
}
