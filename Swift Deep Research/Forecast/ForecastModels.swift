import Foundation
import SwiftData
import SwiftUI

// MARK: - Pipeline stage model (UI)

/// The six MiroFish pipeline stages in fixed order, with display metadata. The
/// `key` matches the stage keys in `pipeline_state.json` / the `stages` map.
public enum ForecastStageKind: String, CaseIterable, Sendable, Identifiable {
    case research, ontology, graph, prepare, run, report
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .research: "Deep Research"
        case .ontology: "Ontology"
        case .graph:    "Knowledge Graph"
        case .prepare:  "Agent Setup"
        case .run:      "Simulation"
        case .report:   "Prediction Report"
        }
    }

    public var subtitle: String {
        switch self {
        case .research: "DeerFlow gathers a cited dossier"
        case .ontology: "Extract the actor entity/edge types"
        case .graph:    "Build the temporal knowledge graph (Zep)"
        case .prepare:  "Turn actors into agents + personas"
        case .run:      "OASIS social simulation (Twitter + Reddit)"
        case .report:   "ReAct agent writes the forecast"
        }
    }

    public var systemImage: String {
        switch self {
        case .research: "magnifyingglass"
        case .ontology: "list.bullet.rectangle"
        case .graph:    "point.3.connected.trianglepath.dotted"
        case .prepare:  "person.3.sequence"
        case .run:      "waveform.path.ecg"
        case .report:   "doc.text.magnifyingglass"
        }
    }
}

public enum ForecastStageStatus: String, Sendable {
    case pending, running, completed, failed, skipped

    public init(apiValue: String?) {
        self = ForecastStageStatus(rawValue: apiValue ?? "pending") ?? .pending
    }
}

/// One row in the stage stepper.
public struct ForecastStage: Sendable, Identifiable {
    public let kind: ForecastStageKind
    public var status: ForecastStageStatus
    public var progress: Int
    public var message: String
    public var id: String { kind.rawValue }

    public init(kind: ForecastStageKind,
                status: ForecastStageStatus = .pending,
                progress: Int = 0,
                message: String = "") {
        self.kind = kind
        self.status = status
        self.progress = progress
        self.message = message
    }
}

// MARK: - Knowledge graph view-model (drives the Grape renderer)

/// A force-graph-ready snapshot built from MiroFish's `/api/graph/data`. Node ids
/// are the Zep node UUIDs (uniform `String` id type that Grape requires).
public struct ForecastGraph: Sendable, Codable, Equatable {
    public var nodes: [GraphVizNode]
    public var edges: [GraphVizEdge]
    /// Distinct entity types present, sorted — drives the colour legend.
    public var entityTypes: [String]
    public var truncated: Bool          // true if we capped the node count
    public var totalNodeCount: Int
    public var totalEdgeCount: Int

    public init(nodes: [GraphVizNode] = [], edges: [GraphVizEdge] = [],
                entityTypes: [String] = [], truncated: Bool = false,
                totalNodeCount: Int = 0, totalEdgeCount: Int = 0) {
        self.nodes = nodes
        self.edges = edges
        self.entityTypes = entityTypes
        self.truncated = truncated
        self.totalNodeCount = totalNodeCount
        self.totalEdgeCount = totalEdgeCount
    }

    public var isEmpty: Bool { nodes.isEmpty }

    /// Build from the raw API payload, capping at `maxNodes` highest-degree nodes
    /// (Grape's force sim is ~100× slower in Debug, so a cap keeps it smooth).
    public static func from(_ data: MFGraphData, maxNodes: Int = 140) -> ForecastGraph {
        let totalNodes = data.nodes.count
        let totalEdges = data.edges.count

        // Degree by node uuid (drives which nodes survive a cap).
        var degree: [String: Int] = [:]
        for e in data.edges {
            degree[e.source_node_uuid, default: 0] += 1
            degree[e.target_node_uuid, default: 0] += 1
        }

        let sorted = data.nodes.sorted { (degree[$0.uuid] ?? 0) > (degree[$1.uuid] ?? 0) }
        let kept = Array(sorted.prefix(maxNodes))
        let keptIDs = Set(kept.map(\.uuid))

        let vizNodes = kept.map {
            GraphVizNode(id: $0.uuid, label: $0.displayName, type: $0.entityType,
                         summary: $0.summary ?? "")
        }
        // Keep only edges whose endpoints both survived.
        let vizEdges = data.edges.compactMap { e -> GraphVizEdge? in
            guard keptIDs.contains(e.source_node_uuid), keptIDs.contains(e.target_node_uuid) else { return nil }
            return GraphVizEdge(id: e.uuid, source: e.source_node_uuid,
                                target: e.target_node_uuid, label: e.relationship)
        }
        let types = Set(vizNodes.map(\.type)).sorted()
        return ForecastGraph(nodes: vizNodes, edges: vizEdges, entityTypes: types,
                             truncated: kept.count < totalNodes,
                             totalNodeCount: totalNodes, totalEdgeCount: totalEdges)
    }
}

public struct GraphVizNode: Sendable, Codable, Equatable, Identifiable {
    public let id: String         // Zep node uuid
    public let label: String
    public let type: String       // entity type → colour
    public let summary: String
}

public struct GraphVizEdge: Sendable, Codable, Equatable, Identifiable {
    public let id: String         // edge uuid
    public let source: String     // source node uuid
    public let target: String     // target node uuid
    public let label: String      // relationship / fact_type
}

/// Stable colour assignment for entity types, used by both the graph and legend.
public enum GraphPalette {
    public static let colors: [Color] = [
        .teal, .indigo, .orange, .pink, .green, .purple,
        .blue, .red, .mint, .yellow, .cyan, .brown
    ]
    public static func color(for type: String, in types: [String]) -> Color {
        guard let idx = types.firstIndex(of: type) else { return .gray }
        return colors[idx % colors.count]
    }
}

// MARK: - Configuration (persisted in UserDefaults)

/// Where the MiroFish backend lives and how to reach it. Defaults match the
/// documented side-by-side layout under `~/Downloads/mirofish`.
public struct ForecastConfiguration: Codable, Sendable, Equatable {
    public var repoRootPath: String
    public var hostString: String
    public var defaultDepth: String      // quick | standard | deep
    public var autoLaunchBackend: Bool

    public init(repoRootPath: String,
                hostString: String = "http://127.0.0.1:5001",
                defaultDepth: String = "standard",
                autoLaunchBackend: Bool = true) {
        self.repoRootPath = repoRootPath
        self.hostString = hostString
        self.defaultDepth = defaultDepth
        self.autoLaunchBackend = autoLaunchBackend
    }

    public static func suggestedDefault() -> ForecastConfiguration {
        let home = NSHomeDirectory()
        return ForecastConfiguration(repoRootPath: home + "/Downloads/mirofish/MiroFish-0.1.2")
    }

    public var repoRoot: URL { URL(fileURLWithPath: repoRootPath) }
    public var host: URL { URL(string: hostString) ?? URL(string: "http://127.0.0.1:5001")! }
}

// MARK: - SwiftData record (persistence)

/// A persisted forecast run. Stores enough to re-open a completed forecast (prompt,
/// final report, graph snapshot) and to reconnect to a live pipeline by id.
@Model
public final class ForecastRecord {
    @Attribute(.unique) public var id: UUID
    public var pipelineID: String
    public var prompt: String
    public var mode: String
    public var depth: String
    public var status: String           // running | completed | failed | cancelled
    public var createdAt: Date
    public var updatedAt: Date
    public var globalProgress: Int
    public var reportMarkdown: String
    public var graphJSON: String        // encoded ForecastGraph snapshot
    public var graphID: String?
    public var simulationID: String?
    public var reportID: String?
    /// Last pipeline error, kept so a failed run still explains itself after
    /// relaunch. Optional for lightweight migration of pre-existing stores.
    public var errorText: String?

    public init(id: UUID = UUID(),
                pipelineID: String,
                prompt: String,
                mode: String,
                depth: String,
                status: String = "running",
                createdAt: Date = .now,
                globalProgress: Int = 0,
                reportMarkdown: String = "",
                graphJSON: String = "",
                graphID: String? = nil,
                simulationID: String? = nil,
                reportID: String? = nil) {
        self.id = id
        self.pipelineID = pipelineID
        self.prompt = prompt
        self.mode = mode
        self.depth = depth
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.globalProgress = globalProgress
        self.reportMarkdown = reportMarkdown
        self.graphJSON = graphJSON
        self.graphID = graphID
        self.simulationID = simulationID
        self.reportID = reportID
    }

    public var titleSummary: String { String(prompt.prefix(80)) }

    /// Decode the stored graph snapshot (empty if none).
    public var graphSnapshot: ForecastGraph? {
        guard !graphJSON.isEmpty, let data = graphJSON.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ForecastGraph.self, from: data)
    }
}
