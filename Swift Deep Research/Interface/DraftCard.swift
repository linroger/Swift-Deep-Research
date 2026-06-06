import SwiftUI
import MarkdownUI

struct DraftCard: View {
    let markdown: String
    let citations: [Citation]
    let sources: [FetchedSource]
    let discovered: [DiscoveredSource]

    @State private var showAllSources = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            InlineCitationsView(markdown: stripFinalSourcesSection(from: markdown),
                                sources: orderedSources,
                                discovered: discovered,
                                citations: citations)
            if !orderedSources.isEmpty {
                Divider()
                numberedSourceList
            }
            if !citations.isEmpty {
                Divider()
                quotedCitations
            }
        }
        .padding(16)
        .glassCard()
    }

    private var header: some View {
        HStack {
            Label("Synthesis", systemImage: "doc.text.fill")
                .font(.headline)
            Spacer()
            if !orderedSources.isEmpty {
                Label("\(orderedSources.count)", systemImage: "link")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.thinMaterial, in: Capsule())
            }
            if !citations.isEmpty {
                Label("\(citations.count)", systemImage: "quote.bubble.fill")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.thinMaterial, in: Capsule())
            }
        }
    }

    private var orderedSources: [FetchedSource] {
        // Citation order is "first appearance" — which is the order the
        // synthesizer used when it numbered them. The engine stores fetched
        // sources in that order already, but the UI builds a stable dedup.
        var seen: Set<URL> = []
        var out: [FetchedSource] = []
        for s in sources where !seen.contains(s.url) {
            seen.insert(s.url); out.append(s)
        }
        return out
    }

    private var numberedSourceList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Sources").font(.subheadline.weight(.semibold))
                Spacer()
                Button(showAllSources ? "Hide all" : "Show all") {
                    withAnimation { showAllSources.toggle() }
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.tint)
            }
            let visible = showAllSources ? orderedSources : Array(orderedSources.prefix(5))
            ForEach(Array(visible.enumerated()), id: \.element.id) { idx, src in
                NumberedSourceRow(index: idx + 1, source: src)
            }
            if !showAllSources, orderedSources.count > 5 {
                Text("+ \(orderedSources.count - 5) more")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var quotedCitations: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Quoted evidence").font(.subheadline.weight(.semibold))
            FlowLayout(spacing: 6) {
                ForEach(citations) { CitationChip(citation: $0, kbChunk: kbChunk(for: $0)) }
            }
        }
    }

    /// Resolve a KB-backed citation to its retrieved chunk so the chip can open
    /// the reader instead of a dead `kb://` link.
    private func kbChunk(for citation: Citation) -> FetchedSource? {
        guard citation.sourceURL.scheme == "kb" else { return nil }
        return sources.first { $0.url == citation.sourceURL }
    }

    /// Synthesizer appends `## Sources` to the draft. The card renders its own
    /// numbered source list so the markdown duplicate is stripped to avoid the
    /// same list appearing twice.
    private func stripFinalSourcesSection(from text: String) -> String {
        if let range = text.range(of: "\n## Sources", options: .backwards) {
            return String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }
}

private struct NumberedSourceRow: View {
    let index: Int
    let source: FetchedSource
    @Environment(\.openURL) private var openURL
    @State private var hovered = false
    /// KB chunks open in a reader sheet (kb:// has no browser handler).
    @State private var showChunk = false

    var body: some View {
        Button {
            if source.isKnowledgeBase { showChunk = true } else { openURL(source.url) }
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Text("[\(index)]")
                    .font(.caption.weight(.semibold).monospaced())
                    .foregroundStyle(.tint)
                    .frame(width: 30, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text(source.title)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if source.isKnowledgeBase {
                        HStack(spacing: 5) {
                            Label("Knowledge base", systemImage: "text.book.closed.fill")
                                .font(.caption2)
                                .foregroundStyle(.indigo)
                            KBScoreBadge(score: source.relevanceScore)
                        }
                    } else {
                        Text(source.url.host ?? source.url.absoluteString)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                if hovered {
                    Image(systemName: source.isKnowledgeBase ? "doc.text.magnifyingglass" : "arrow.up.right.square")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(hovered ? Color.accentColor.opacity(0.10) : Color.clear,
                       in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(source.isKnowledgeBase
              ? "\(source.title) — knowledge base\n\n\(String(source.extractedText.prefix(280)))…"
              : "\(source.title)\n\(source.url.absoluteString)\n\n\(String(source.extractedText.prefix(280)))…")
        .sheet(isPresented: $showChunk) { KBChunkDetail(source: source) }
    }
}

struct CitationChip: View {
    let citation: Citation
    /// Resolved KB chunk for `kb://` citations; opens the reader instead of a
    /// dead browser link.
    var kbChunk: FetchedSource? = nil
    @Environment(\.openURL) private var openURL
    @State private var hovered = false
    @State private var showChunk = false

    private var isKB: Bool { citation.sourceURL.scheme == "kb" }

    var body: some View {
        Button {
            if kbChunk != nil {
                showChunk = true
            } else if !isKB {
                openURL(citation.sourceURL)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isKB ? "text.book.closed.fill" : "quote.bubble")
                    .font(.caption2)
                Text(isKB ? "Knowledge base" : citation.sourceTitle)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(hovered ? Color.accentColor.opacity(0.20) : Color.accentColor.opacity(0.10),
                       in: Capsule())
            .foregroundStyle(.tint)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help("\(citation.claim)\n\n“\(citation.exactQuote)”")
        .sheet(isPresented: $showChunk) {
            if let kbChunk { KBChunkDetail(source: kbChunk) }
        }
    }
}

/// Minimal wrapping flow layout for chip rows.
struct FlowLayout: Layout {
    let spacing: CGFloat
    init(spacing: CGFloat = 6) { self.spacing = spacing }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var line: CGFloat = 0
        var totalHeight: CGFloat = 0
        var lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if line + size.width > maxWidth {
                totalHeight += lineHeight + spacing
                line = 0; lineHeight = 0
            }
            line += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: maxWidth, height: totalHeight + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
