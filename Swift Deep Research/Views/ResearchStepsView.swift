import SwiftUI

/// Displays detailed research steps and progress during an ongoing research session
struct ResearchStepsView: View {
    let progress: ResearchProgress
    @State private var isExpanded = true
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header with toggle
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(width: 16)
                    
                    Text("Research Progress")
                        .font(.caption)
                        .fontWeight(.semibold)
                    
                    Spacer()
                    
                    // Summary stats
                    HStack(spacing: 12) {
                        if !progress.searchQueries.isEmpty {
                            Label("\(progress.searchQueries.count)", systemImage: "magnifyingglass")
                        }
                        if progress.sourcesFound > 0 {
                            Label("\(progress.sourcesProcessed)/\(progress.sourcesFound)", systemImage: "doc.text")
                        }
                        Label("\(progress.steps.count)", systemImage: "list.bullet")
                    }
                    .font(.caption2)
                    .foregroundColor(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(NSColor.controlBackgroundColor))
            }
            .buttonStyle(.plain)
            
            if isExpanded {
                Divider()
                
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        // Current activity indicator
                        if !progress.urlsBeingRead.isEmpty {
                            CurrentActivityView(urls: progress.urlsBeingRead, phase: progress.phase)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                        }
                        
                        // Steps list
                        ForEach(Array(progress.steps.enumerated().reversed()), id: \.element.id) { index, step in
                            ResearchStepRow(step: step, isLatest: index == progress.steps.count - 1)
                        }
                    }
                }
                .frame(maxHeight: 200)
            }
        }
        .background(Color(NSColor.textBackgroundColor))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.accentColor.opacity(0.3), lineWidth: 1)
        )
    }
}

/// Shows the current activity (URLs being read)
struct CurrentActivityView: View {
    let urls: [String]
    let phase: ResearchProgress.ResearchPhase
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                ProgressView()
                    .scaleEffect(0.6)
                Text(phase.rawValue)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.accentColor)
            }
            
            ForEach(urls.prefix(5), id: \.self) { url in
                HStack(spacing: 4) {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 8))
                        .foregroundColor(.secondary)
                    Text(shortenURL(url))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                .padding(.leading, 20)
            }
            
            if urls.count > 5 {
                Text("+ \(urls.count - 5) more...")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.leading, 20)
            }
        }
        .padding(8)
        .background(Color.accentColor.opacity(0.1))
        .cornerRadius(6)
    }
    
    private func shortenURL(_ url: String) -> String {
        guard let urlObj = URL(string: url) else { return url }
        return urlObj.host ?? url
    }
}

/// A single research step row
struct ResearchStepRow: View {
    let step: ResearchStep
    let isLatest: Bool
    @State private var isExpanded = false
    @ObservedObject private var settings = AppSettings.shared
    
    // Auto-expand reasoning steps if setting is enabled
    private var shouldShowDetail: Bool {
        if step.type == .thinking && settings.showReasoningTraces {
            return true
        }
        return isExpanded
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if step.detail != nil || step.urls != nil {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isExpanded.toggle()
                    }
                }
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    // Icon with better styling for thinking steps
                    ZStack {
                        if step.type == .thinking {
                            Circle()
                                .fill(iconColor.opacity(0.2))
                                .frame(width: 20, height: 20)
                            Image(systemName: step.type.rawValue)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(iconColor)
                        } else {
                            Image(systemName: step.type.rawValue)
                                .font(.system(size: 10))
                                .foregroundColor(iconColor)
                                .frame(width: 16, height: 16)
                                .background(iconColor.opacity(0.15))
                                .cornerRadius(4)
                        }
                    }
                    .frame(width: 20, height: 20)
                    
                    // Content
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            // Special label for reasoning
                            if step.type == .thinking {
                                HStack(spacing: 4) {
                                    Text(step.title)
                                        .font(.caption)
                                        .fontWeight(.medium)
                                        .foregroundColor(.purple)
                                    
                                    Text("• Reasoning")
                                        .font(.caption2)
                                        .foregroundColor(.purple.opacity(0.7))
                                }
                            } else {
                                Text(step.title)
                                    .font(.caption)
                                    .fontWeight(isLatest ? .medium : .regular)
                                    .foregroundColor(isLatest ? .primary : .secondary)
                            }
                            
                            Spacer()
                            
                            Text(step.timestamp.formatted(date: .omitted, time: .shortened))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        
                        // Preview of detail if not expanded
                        if !shouldShowDetail, let detail = step.detail {
                            Text(detail)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                    
                    // Expand indicator
                    if step.detail != nil || step.urls != nil {
                        Image(systemName: shouldShowDetail ? "chevron.up" : "chevron.down")
                            .font(.system(size: 8))
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(backgroundForStep)
            }
            .buttonStyle(.plain)
            
            // Expanded content - show reasoning traces prominently
            if shouldShowDetail {
                VStack(alignment: .leading, spacing: 6) {
                    if let detail = step.detail {
                        if step.type == .thinking {
                            // Special formatting for reasoning traces
                            ReasoningTraceView(text: detail)
                        } else {
                            Text(detail)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .textSelection(.enabled)
                                .padding(8)
                                .background(Color(NSColor.controlBackgroundColor))
                                .cornerRadius(4)
                        }
                    }
                    
                    if let urls = step.urls, !urls.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("URLs:")
                                .font(.caption2)
                                .fontWeight(.medium)
                            
                            ForEach(urls, id: \.self) { url in
                                Link(destination: URL(string: url) ?? URL(string: "https://example.com")!) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "link")
                                            .font(.system(size: 8))
                                        Text(url)
                                            .lineLimit(1)
                                    }
                                    .font(.caption2)
                                }
                            }
                        }
                        .padding(8)
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(4)
                    }
                }
                .padding(.horizontal, 36)
                .padding(.bottom, 8)
            }
            
            Divider()
                .padding(.leading, 36)
        }
    }
    
    private var iconColor: Color {
        switch step.type {
        case .query: return .blue
        case .search: return .orange
        case .reading: return .green
        case .thinking: return .purple
        case .answer: return .green
        case .error: return .red
        }
    }
    
    private var backgroundForStep: Color {
        if step.type == .thinking {
            return Color.purple.opacity(0.08)
        } else if isLatest {
            return Color.accentColor.opacity(0.05)
        }
        return Color.clear
    }
}

/// Displays reasoning traces with special formatting
struct ReasoningTraceView: View {
    let text: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            HStack(spacing: 6) {
                Image(systemName: "brain")
                    .font(.caption2)
                    .foregroundColor(.purple)
                Text("Model Reasoning")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundColor(.purple)
            }
            
            // Content with proper formatting
            ScrollView {
                Text(text)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.primary.opacity(0.85))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 150)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.purple.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.purple.opacity(0.2), lineWidth: 1)
                )
        )
    }
}

// MARK: - Preview

struct ResearchStepsView_Previews: PreviewProvider {
    static var previews: some View {
        let progress = ResearchProgress(
            phase: .extractingContent,
            currentQuery: "test query",
            sourcesFound: 10,
            sourcesProcessed: 5,
            iterations: 2,
            statusMessage: "Reading sources...",
            steps: [
                ResearchStep(timestamp: Date(), type: .query, title: "Research question", detail: "What is the peloponnesian war?"),
                ResearchStep(timestamp: Date(), type: .query, title: "Generated 3 search queries", detail: "• peloponnesian war history\n• ancient greek war sparta athens\n• peloponnesian war causes"),
                ResearchStep(timestamp: Date(), type: .search, title: "Searching", detail: "peloponnesian war history"),
                ResearchStep(timestamp: Date(), type: .reading, title: "Reading 4 sources", detail: "• Wikipedia\n• Britannica\n• History.com\n• Ancient.eu", urls: ["https://wikipedia.org", "https://britannica.com"]),
                ResearchStep(timestamp: Date(), type: .thinking, title: "Analyzing content", detail: "Processing 4 sources")
            ],
            searchQueries: ["query1", "query2"],
            urlsBeingRead: ["https://wikipedia.org/wiki/Peloponnesian_War", "https://britannica.com/event/Peloponnesian-War"],
            currentThinking: nil
        )
        
        ResearchStepsView(progress: progress)
            .frame(width: 400)
            .padding()
    }
}
