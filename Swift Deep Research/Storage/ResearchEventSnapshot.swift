import Foundation

/// Loss-less `Codable` mirror of `ResearchEvent`, used to persist a full,
/// replayable event log into `StoredEvent.eventPayloadJSON`.
///
/// `ResearchEvent` itself is not `Codable`: its `.sessionCompleted` case carries a
/// `Duration` and historically the persistence layer hand-rolled an envelope that
/// only encoded three kinds (`planEmitted`, `draftReady`, `citationAdded`),
/// dropping every other kind's associated values. This snapshot encodes EVERY
/// kind's payload so a completed session can be reconstructed from its events
/// (tool outcomes, fetched-source details, reflection critiques, errors included).
///
/// Every associated-value type on `ResearchEvent` is already `Codable` except
/// `Duration`, which is encoded explicitly as whole + attosecond components via
/// `DurationComponents` so the round-trip is exact and portable across OS versions.
///
/// The representation is a tagged struct (a `kind` discriminator plus a flat set of
/// optional payload fields) rather than an enum with associated values, so adding
/// or reordering cases never invalidates JSON already on disk and decoding an
/// unknown/legacy `kind` degrades gracefully instead of throwing.
public struct ResearchEventSnapshot: Codable, Sendable {
    public let kind: String
    public let timestamp: Date

    // Payload carriers — exactly the subset relevant to `kind` is non-nil.
    public let sessionDescriptor: SessionDescriptor?
    public let round: Int?
    public let roundOf: Int?
    public let plan: ResearchPlan?
    public let workerDescriptor: WorkerDescriptor?
    public let workerID: WorkerID?
    public let message: String?
    public let toolInvocation: ToolInvocation?
    public let toolOutcome: ToolOutcome?
    public let discoveredSource: DiscoveredSource?
    public let fetchedSource: FetchedSource?
    public let url: URL?
    public let stage: ResearchEvent.Stage?
    public let text: String?
    public let citation: Citation?
    public let summary: String?
    public let draft: DraftDescriptor?
    public let critique: Reflector.Critique?
    public let continuing: Bool?
    public let remainingGaps: Int?
    public let elapsed: DurationComponents?
    public let totalTokens: Int?
    public let warning: String?
    public let failure: EngineFailure?

    /// `Duration` is not `Codable`; persist its two-component `(seconds, attoseconds)`
    /// representation so the round-trip is lossless and stable.
    public struct DurationComponents: Codable, Sendable {
        public let seconds: Int64
        public let attoseconds: Int64
        public init(_ duration: Duration) {
            let c = duration.components
            self.seconds = c.seconds
            self.attoseconds = c.attoseconds
        }
        public var duration: Duration {
            Duration(secondsComponent: seconds, attosecondsComponent: attoseconds)
        }
    }

    /// Build a loss-less snapshot from a live event. `timestamp` defaults to now,
    /// matching the prior envelope's behavior (events were stamped at persist time).
    public init(event: ResearchEvent, timestamp: Date = .now) {
        self.timestamp = timestamp
        // Initialize every carrier to nil, then fill only the ones the case uses.
        var sessionDescriptor: SessionDescriptor?
        var round: Int?
        var roundOf: Int?
        var plan: ResearchPlan?
        var workerDescriptor: WorkerDescriptor?
        var workerID: WorkerID?
        var message: String?
        var toolInvocation: ToolInvocation?
        var toolOutcome: ToolOutcome?
        var discoveredSource: DiscoveredSource?
        var fetchedSource: FetchedSource?
        var url: URL?
        var stage: ResearchEvent.Stage?
        var text: String?
        var citation: Citation?
        var summary: String?
        var draft: DraftDescriptor?
        var critique: Reflector.Critique?
        var continuing: Bool?
        var remainingGaps: Int?
        var elapsed: DurationComponents?
        var totalTokens: Int?
        var warning: String?
        var failure: EngineFailure?

        let kind: String
        switch event {
        case .sessionStarted(let d):
            kind = "sessionStarted"; sessionDescriptor = d
        case .iterationStarted(let r, let of):
            kind = "iterationStarted"; round = r; roundOf = of
        case .planEmitted(let p):
            kind = "planEmitted"; plan = p
        case .workerStarted(let d):
            kind = "workerStarted"; workerDescriptor = d
        case .workerProgress(let id, let m):
            kind = "workerProgress"; workerID = id; message = m
        case .toolInvoked(let id, let inv):
            kind = "toolInvoked"; workerID = id; toolInvocation = inv
        case .toolResult(let id, let inv, let outcome):
            kind = "toolResult"; workerID = id; toolInvocation = inv; toolOutcome = outcome
        case .sourceDiscovered(let id, let s):
            kind = "sourceDiscovered"; workerID = id; discoveredSource = s
        case .sourceFetched(let id, let f):
            kind = "sourceFetched"; workerID = id; fetchedSource = f
        case .sourceCacheHit(let id, let u):
            kind = "sourceCacheHit"; workerID = id; url = u
        case .reasoningDelta(let id, let t):
            kind = "reasoningDelta"; workerID = id; text = t
        case .tokenDelta(let st, let t):
            kind = "tokenDelta"; stage = st; text = t
        case .citationAdded(let c):
            kind = "citationAdded"; citation = c
        case .workerCompleted(let id, let s):
            kind = "workerCompleted"; workerID = id; summary = s
        case .draftReady(let d):
            kind = "draftReady"; draft = d
        case .reflectionStarted(let r):
            kind = "reflectionStarted"; round = r
        case .reflectionEmitted(let c):
            kind = "reflectionEmitted"; critique = c
        case .reflectionConcluded(let cont, let n):
            kind = "reflectionConcluded"; continuing = cont; remainingGaps = n
        case .sessionCompleted(let e, let t):
            kind = "sessionCompleted"; elapsed = DurationComponents(e); totalTokens = t
        case .warning(let s):
            kind = "warning"; warning = s
        case .error(let f):
            kind = "error"; failure = f
        }
        self.kind = kind
        self.sessionDescriptor = sessionDescriptor
        self.round = round
        self.roundOf = roundOf
        self.plan = plan
        self.workerDescriptor = workerDescriptor
        self.workerID = workerID
        self.message = message
        self.toolInvocation = toolInvocation
        self.toolOutcome = toolOutcome
        self.discoveredSource = discoveredSource
        self.fetchedSource = fetchedSource
        self.url = url
        self.stage = stage
        self.text = text
        self.citation = citation
        self.summary = summary
        self.draft = draft
        self.critique = critique
        self.continuing = continuing
        self.remainingGaps = remainingGaps
        self.elapsed = elapsed
        self.totalTokens = totalTokens
        self.warning = warning
        self.failure = failure
    }

    /// Reconstruct the original `ResearchEvent` from a decoded snapshot, when every
    /// field the `kind` requires is present. Returns `nil` for an unrecognized
    /// `kind` or a payload missing a required field, so a corrupt/forward-version
    /// row degrades to "summary only" rather than crashing a replay.
    public var event: ResearchEvent? {
        switch kind {
        case "sessionStarted":
            return sessionDescriptor.map(ResearchEvent.sessionStarted)
        case "iterationStarted":
            guard let round, let roundOf else { return nil }
            return .iterationStarted(round: round, of: roundOf)
        case "planEmitted":
            return plan.map(ResearchEvent.planEmitted)
        case "workerStarted":
            return workerDescriptor.map(ResearchEvent.workerStarted)
        case "workerProgress":
            guard let workerID, let message else { return nil }
            return .workerProgress(workerID, message: message)
        case "toolInvoked":
            guard let workerID, let toolInvocation else { return nil }
            return .toolInvoked(workerID, toolInvocation)
        case "toolResult":
            guard let workerID, let toolInvocation, let toolOutcome else { return nil }
            return .toolResult(workerID, toolInvocation, toolOutcome)
        case "sourceDiscovered":
            guard let workerID, let discoveredSource else { return nil }
            return .sourceDiscovered(workerID, discoveredSource)
        case "sourceFetched":
            guard let workerID, let fetchedSource else { return nil }
            return .sourceFetched(workerID, fetchedSource)
        case "sourceCacheHit":
            guard let workerID, let url else { return nil }
            return .sourceCacheHit(workerID, url)
        case "reasoningDelta":
            guard let workerID, let text else { return nil }
            return .reasoningDelta(workerID, text)
        case "tokenDelta":
            guard let stage, let text else { return nil }
            return .tokenDelta(stage: stage, text: text)
        case "citationAdded":
            return citation.map(ResearchEvent.citationAdded)
        case "workerCompleted":
            guard let workerID, let summary else { return nil }
            return .workerCompleted(workerID, summary: summary)
        case "draftReady":
            return draft.map(ResearchEvent.draftReady)
        case "reflectionStarted":
            return round.map { ResearchEvent.reflectionStarted(round: $0) }
        case "reflectionEmitted":
            return critique.map(ResearchEvent.reflectionEmitted)
        case "reflectionConcluded":
            guard let continuing, let remainingGaps else { return nil }
            return .reflectionConcluded(continuing: continuing, remainingGaps: remainingGaps)
        case "sessionCompleted":
            guard let elapsed, let totalTokens else { return nil }
            return .sessionCompleted(elapsed: elapsed.duration, totalTokens: totalTokens)
        case "warning":
            return warning.map(ResearchEvent.warning)
        case "error":
            return failure.map(ResearchEvent.error)
        default:
            return nil
        }
    }
}
