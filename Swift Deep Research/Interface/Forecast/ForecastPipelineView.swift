import SwiftUI

/// The active forecast: a header with overall progress, a horizontal stage
/// stepper, and the selected stage's detail panel. Auto-follows the running
/// stage unless the user pins one.
struct ForecastPipelineView: View {
    let run: ForecastRun
    let onNewForecast: () -> Void

    @State private var manualSelection: ForecastStageKind?

    private var activeStage: ForecastStageKind {
        manualSelection ?? ForecastStageKind(rawValue: run.currentStage) ?? run.stages.first?.kind ?? .research
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if run.phase == .failed || run.phase == .cancelled {
                errorBanner(run.errorMessage ?? (run.phase == .cancelled
                    ? "The pipeline was stopped before it finished."
                    : "The MiroFish pipeline failed."))
            }
            Divider()
            stepper
            Divider()
            stageDetail(activeStage)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: run.currentStage) {
            // Resume auto-follow whenever the pipeline advances to a new stage.
            manualSelection = nil
        }
    }

    /// Why the run stopped — including MiroFish's preflight bullet lists (missing
    /// Zep key, missing provider key, …), which arrive as multi-line messages.
    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(run.phase == .cancelled ? "Forecast cancelled" : "Forecast stopped")
                    .font(.subheadline.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if run.pipelineID != nil {
                Button { run.resume() } label: {
                    Label("Resume", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
                .help("Restart from the first incomplete stage — finished research, graph, and simulation artifacts are reused.")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08))
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(run.prompt)
                        .font(.headline)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        statusPill
                        Text(run.mode.label).font(.caption2).foregroundStyle(.secondary)
                        Text("·").foregroundStyle(.tertiary)
                        Text("depth: \(run.depth)").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 12)
                controls
            }
            HStack(spacing: 8) {
                ProgressView(value: Double(run.globalProgress), total: 100)
                    .tint(progressTint)
                Text("\(run.globalProgress)%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 38, alignment: .trailing)
            }
        }
        .padding(16)
    }

    private var statusPill: some View {
        let (text, color, icon): (String, Color, String) = {
            switch run.phase {
            case .idle, .starting: return ("Starting", .gray, "hourglass")
            case .running: return ("Running", .blue, "circle.dotted")
            case .completed: return ("Complete", .green, "checkmark.circle.fill")
            case .failed: return ("Failed", .red, "exclamationmark.triangle.fill")
            case .cancelled: return ("Cancelled", .orange, "stop.circle.fill")
            }
        }()
        return Label(text, systemImage: icon)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
    }

    private var progressTint: Color {
        switch run.phase {
        case .failed: .red
        case .completed: .green
        case .cancelled: .orange
        default: .accentColor
        }
    }

    @ViewBuilder
    private var controls: some View {
        HStack(spacing: 8) {
            if run.phase.isActive {
                Button(role: .destructive) { run.cancel() } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .controlSize(.small)
            }
            if run.isRestored, run.pipelineID != nil, !run.phase.isTerminal {
                Button { run.resumePolling() } label: { Label("Resume", systemImage: "play.fill") }
                    .controlSize(.small)
            }
            Button { onNewForecast() } label: { Label("New", systemImage: "plus") }
                .controlSize(.small)
        }
        .labelStyle(.titleAndIcon)
    }

    // MARK: - Stage stepper

    private var stepper: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(run.stages) { stage in
                    stageChip(stage)
                        .onTapGesture { manualSelection = stage.kind }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    private func stageChip(_ stage: ForecastStage) -> some View {
        let isActive = stage.kind == activeStage
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                stageIcon(stage)
                Text(stage.kind.title).font(.caption.weight(.semibold)).lineLimit(1)
            }
            Text(stage.kind.subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if stage.status == .running, stage.progress > 0 {
                ProgressView(value: Double(stage.progress), total: 100)
                    .tint(.accentColor)
                    .scaleEffect(y: 0.6, anchor: .center)
            }
        }
        .padding(10)
        .frame(width: 168, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isActive ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isActive ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.06),
                              lineWidth: isActive ? 1 : 0.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func stageIcon(_ stage: ForecastStage) -> some View {
        switch stage.status {
        case .completed:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .running:
            ProgressView().controlSize(.mini)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
        case .skipped:
            Image(systemName: "minus.circle").foregroundStyle(.tertiary)
        case .pending:
            Image(systemName: stage.kind.systemImage).foregroundStyle(.tertiary)
        }
    }

    // MARK: - Stage detail router

    @ViewBuilder
    private func stageDetail(_ kind: ForecastStageKind) -> some View {
        switch kind {
        case .research:
            ResearchConsoleView(run: run)
        case .ontology:
            OntologyStageView(run: run)
        case .graph:
            KnowledgeGraphView(graph: run.graph ?? ForecastGraph())
                .padding(12)
        case .prepare:
            AgentSetupStageView(run: run)
        case .run:
            SimulationStageView(run: run)
        case .report:
            ForecastReportView(run: run)
        }
    }
}

// MARK: - Ontology stage

/// Stage 2 panel: the extracted actor ontology (entity + edge types). Falls back
/// to the live knowledge-graph entity types if the project ontology isn't loaded.
struct OntologyStageView: View {
    let run: ForecastRun

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let ontology = run.ontology, hasContent(ontology) {
                    if let entities = ontology.entity_types, !entities.isEmpty {
                        typeSection("Entity types", systemImage: "circle.grid.2x2.fill",
                                    accent: .indigo, types: entities)
                    }
                    if let edges = ontology.edge_types, !edges.isEmpty {
                        typeSection("Relationship types", systemImage: "arrow.left.arrow.right",
                                    accent: .teal, types: edges)
                    }
                } else if let graph = run.graph, !graph.entityTypes.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Entity types", systemImage: "circle.grid.2x2.fill")
                            .font(.headline).foregroundStyle(.indigo)
                        FlowLayout(spacing: 8) {
                            ForEach(graph.entityTypes, id: \.self) { type in
                                Label(type, systemImage: "circle.fill")
                                    .font(.caption)
                                    .labelStyle(.titleAndIcon)
                                    .foregroundStyle(GraphPalette.color(for: type, in: graph.entityTypes))
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .background(.quaternary.opacity(0.4), in: Capsule())
                            }
                        }
                    }
                } else {
                    pending
                }
            }
            .padding(16)
        }
    }

    private func hasContent(_ o: MFOntology) -> Bool {
        (o.entity_types?.isEmpty == false) || (o.edge_types?.isEmpty == false)
    }

    private func typeSection(_ title: String, systemImage: String, accent: Color,
                             types: [MFOntologyType]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("\(title) (\(types.count))", systemImage: systemImage)
                .font(.headline).foregroundStyle(accent)
            ForEach(types) { type in
                VStack(alignment: .leading, spacing: 2) {
                    Text(type.name).font(.callout.weight(.semibold))
                    if let desc = type.description, !desc.isEmpty {
                        Text(desc).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var pending: some View {
        ContentUnavailableView {
            Label("Ontology pending", systemImage: "list.bullet.rectangle")
        } description: {
            Text("MiroFish first decides what kinds of real-world actors matter — the entity and relationship types it will extract into the graph.")
        }
    }
}

// MARK: - Agent setup stage

/// Stage 4 panel: turning graph entities into LLM agents with personas. The
/// pipeline doesn't expose per-persona detail mid-run, so this summarises the
/// stage and surfaces the simulation scale once known.
struct AgentSetupStageView: View {
    let run: ForecastRun

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                let prepare = run.stages.first(where: { $0.kind == .prepare })
                if prepare?.status == .running || prepare?.status == .completed {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Building agents", systemImage: "person.3.sequence.fill")
                            .font(.headline).foregroundStyle(.pink)
                        if let msg = prepare?.message, !msg.isEmpty {
                            Text(msg).font(.callout).foregroundStyle(.secondary)
                        }
                        if let count = run.runState?.total_rounds, count > 0 {
                            Text("Simulation configured for \(count) rounds.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(14)
                    .glassCard()
                } else {
                    ContentUnavailableView {
                        Label("Agent setup pending", systemImage: "person.3.sequence")
                    } description: {
                        Text("Each graph actor becomes an autonomous LLM agent with a persona, memory, and posting behaviour before the simulation runs.")
                    }
                }
            }
            .padding(16)
        }
    }
}
