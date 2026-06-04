import Foundation

/// Single stream type that drives every UI update during a research run.
///
/// The orchestrator and every worker share one `AsyncThrowingStream<ResearchEvent, Error>`.
/// The UI subscribes once and pattern-matches; there is no other communication channel.
public enum ResearchEvent: Sendable, Identifiable {
    case sessionStarted(SessionDescriptor)
    case iterationStarted(round: Int, of: Int)
    case planEmitted(ResearchPlan)
    case workerStarted(WorkerDescriptor)
    case workerProgress(WorkerID, message: String)
    case toolInvoked(WorkerID, ToolInvocation)
    case toolResult(WorkerID, ToolInvocation, ToolOutcome)
    case sourceDiscovered(WorkerID, DiscoveredSource)
    case sourceFetched(WorkerID, FetchedSource)
    case sourceCacheHit(WorkerID, URL)
    case reasoningDelta(WorkerID, String)
    case tokenDelta(stage: Stage, text: String)
    case citationAdded(Citation)
    case workerCompleted(WorkerID, summary: String)
    case draftReady(DraftDescriptor)
    case reflectionStarted(round: Int)
    case reflectionEmitted(Reflector.Critique)
    case reflectionConcluded(continuing: Bool, remainingGaps: Int)
    case sessionCompleted(elapsed: Duration, totalTokens: Int)
    case warning(String)
    case error(EngineFailure)

    public enum Stage: String, Sendable, Codable { case planning, worker, synthesis }

    public var id: String {
        switch self {
        case .sessionStarted(let d): "session.\(d.id)"
        case .iterationStarted(let r, _): "iter.\(r)"
        case .planEmitted(let p): "plan.\(p.id)"
        case .workerStarted(let w): "worker.start.\(w.id.raw)"
        case .workerProgress(let id, let m): "worker.progress.\(id.raw).\(m.hashValue)"
        case .toolInvoked(let id, let t): "tool.invoke.\(id.raw).\(t.id)"
        case .toolResult(let id, let t, _): "tool.result.\(id.raw).\(t.id)"
        case .sourceDiscovered(_, let s): "source.disc.\(s.id)"
        case .sourceFetched(_, let s): "source.fetch.\(s.id)"
        case .sourceCacheHit(let id, let url): "source.cache.\(id.raw).\(url.absoluteString.hashValue)"
        case .reasoningDelta(let id, let s): "reason.\(id.raw).\(s.hashValue)"
        case .tokenDelta(let stage, let t): "tok.\(stage.rawValue).\(t.hashValue)"
        case .citationAdded(let c): "cite.\(c.id)"
        case .workerCompleted(let id, _): "worker.done.\(id.raw)"
        case .draftReady(let d): "draft.\(d.id)"
        case .reflectionStarted(let r): "reflect.start.\(r)"
        case .reflectionEmitted(let c): "reflect.\(c.verdict.rawValue).\(c.gaps.count)"
        case .reflectionConcluded(let cont, let n): "reflect.done.\(cont).\(n)"
        case .sessionCompleted: "session.done"
        case .warning(let s): "warn.\(s.hashValue)"
        case .error(let e): "err.\(e.id)"
        }
    }
}

public struct SessionDescriptor: Sendable, Identifiable, Codable {
    public let id: UUID
    public let query: String
    public let createdAt: Date
    public let providerName: String

    public init(id: UUID = UUID(), query: String, createdAt: Date = .now, providerName: String) {
        self.id = id; self.query = query; self.createdAt = createdAt; self.providerName = providerName
    }
}

public struct WorkerID: Sendable, Hashable, Codable, RawRepresentable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public var raw: String { rawValue }
    public static func make(_ task: String) -> WorkerID {
        WorkerID(rawValue: "w-\(task.hashValue.magnitude % 0xFFFF)-\(UUID().uuidString.prefix(6))")
    }
}

public struct WorkerDescriptor: Sendable, Codable {
    public let id: WorkerID
    public let task: String
    public let rationale: String
    public init(id: WorkerID, task: String, rationale: String) {
        self.id = id; self.task = task; self.rationale = rationale
    }
}

public struct ToolInvocation: Sendable, Codable, Identifiable {
    public let id: String
    public let name: String
    public let argumentsJSON: String
    public init(id: String = UUID().uuidString, name: String, argumentsJSON: String) {
        self.id = id; self.name = name; self.argumentsJSON = argumentsJSON
    }
}

public enum ToolOutcome: Sendable, Codable {
    case ok(summary: String, payloadJSON: String)
    case failed(message: String)
}

public struct DiscoveredSource: Sendable, Codable, Identifiable {
    public let id: String
    public let title: String
    public let url: URL
    public let snippet: String?
    public let provider: String
    public init(id: String = UUID().uuidString, title: String, url: URL, snippet: String?, provider: String) {
        self.id = id; self.title = title; self.url = url; self.snippet = snippet; self.provider = provider
    }
}

public struct FetchedSource: Sendable, Codable, Identifiable {
    public let id: String
    public let url: URL
    public let title: String
    public let extractedText: String
    public let extractedAt: Date
    public let strategy: ExtractionStrategy
    /// Semantic-search relevance score for knowledge-base chunks (0…1, higher is
    /// closer). `nil` for web sources. Surfaced in the inspector so users can see
    /// which private-document chunks the agent retrieved and how relevant they were.
    public let relevanceScore: Double?
    public init(id: String = UUID().uuidString, url: URL, title: String, extractedText: String,
                extractedAt: Date = .now, strategy: ExtractionStrategy,
                relevanceScore: Double? = nil) {
        self.id = id; self.url = url; self.title = title; self.extractedText = extractedText
        self.extractedAt = extractedAt; self.strategy = strategy
        self.relevanceScore = relevanceScore
    }

    /// True when this source came from the user's private knowledge base
    /// (pyseekdb), as opposed to a web fetch.
    public var isKnowledgeBase: Bool { strategy == .knowledgeBase }

    public enum ExtractionStrategy: String, Sendable, Codable {
        case staticHTML, javascriptRendered, reddit, knowledgeBase
    }
}

public struct Citation: Sendable, Codable, Identifiable {
    public let id: String
    public let sourceURL: URL
    public let sourceTitle: String
    public let exactQuote: String
    public let claim: String
    public init(id: String = UUID().uuidString, sourceURL: URL, sourceTitle: String,
                exactQuote: String, claim: String) {
        self.id = id; self.sourceURL = sourceURL; self.sourceTitle = sourceTitle
        self.exactQuote = exactQuote; self.claim = claim
    }
}

public struct DraftDescriptor: Sendable, Codable, Identifiable {
    public let id: UUID
    public let markdown: String
    public let citations: [Citation]
    public let producedAt: Date
    public init(id: UUID = UUID(), markdown: String, citations: [Citation], producedAt: Date = .now) {
        self.id = id; self.markdown = markdown; self.citations = citations; self.producedAt = producedAt
    }
}

public struct EngineFailure: Sendable, Codable, Identifiable, Error {
    public let id: String
    public let kind: Kind
    public let message: String
    public let workerID: WorkerID?
    public let underlying: String?

    public init(id: String = UUID().uuidString, kind: Kind, message: String,
                workerID: WorkerID? = nil, underlying: String? = nil) {
        self.id = id; self.kind = kind; self.message = message
        self.workerID = workerID; self.underlying = underlying
    }

    public enum Kind: String, Sendable, Codable {
        case configurationMissing, providerFailure, toolFailure, budgetExceeded,
             planningFailed, synthesisFailed, cancelled, unknown
    }
}
