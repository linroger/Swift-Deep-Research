import SwiftUI
import MarkdownUI

/// Renders the synthesized draft with inline `[N]` citation markers replaced by
/// tappable, hover-previewing chips. Citations are matched against the
/// session's source list by numeric order of first appearance — the same
/// ordering the synthesizer uses when it builds the `## Sources` section.
struct InlineCitationsView: View {
    let markdown: String
    let sources: [FetchedSource]
    let discovered: [DiscoveredSource]
    let citations: [Citation]

    @State private var hoveredIndex: Int?
    /// KB citation opened in the reader sheet (`kb://` links have no browser
    /// handler, so we intercept them below).
    @State private var inspectedChunk: FetchedSource?

    /// Split the markdown around `[N]` markers and render text + chips.
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                paragraphView(paragraph)
            }
        }
        // Intercept inline citation taps: route `kb://` markers to the chunk
        // reader (a dead link otherwise); let web links open in the browser.
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == "kb" else { return .systemAction }
            if let chunk = sources.first(where: { $0.url == url }) {
                inspectedChunk = chunk
            }
            return .handled   // swallow the dead kb:// link even if unmatched
        })
        .sheet(item: $inspectedChunk) { KBChunkDetail(source: $0) }
    }

    // MARK: - Paragraph rendering

    private var paragraphs: [String] {
        markdown.components(separatedBy: "\n\n")
    }

    @ViewBuilder
    private func paragraphView(_ raw: String) -> some View {
        let segments = Self.tokenize(raw)
        // Headings / lists fall through to MarkdownUI for full styling.
        if raw.hasPrefix("#") || raw.hasPrefix("- ") || raw.hasPrefix("* ") || raw.hasPrefix("1. ") || raw.hasPrefix("|") {
            Markdown(raw)
                .markdownTheme(.gitHub)
                .textSelection(.enabled)
        } else if segments.count == 1, case .text = segments[0] {
            Markdown(raw)
                .markdownTheme(.gitHub)
                .textSelection(.enabled)
        } else {
            chipFlow(segments: segments)
        }
    }

    private func chipFlow(segments: [Segment]) -> some View {
        Text(buildAttributedString(segments: segments))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func buildAttributedString(segments: [Segment]) -> AttributedString {
        var attributed = AttributedString()
        for segment in segments {
            switch segment {
            case .text(let s):
                attributed.append(AttributedString(s))
            case .citation(let n):
                var chip = AttributedString("[\(n)]")
                chip.foregroundColor = .accentColor
                chip.font = .system(.body, design: .default).weight(.medium)
                if let url = url(for: n) {
                    chip.link = url
                }
                attributed.append(chip)
            }
        }
        return attributed
    }

    private func url(for n: Int) -> URL? {
        guard n >= 1, n <= sources.count else { return nil }
        return sources[n - 1].url
    }

    // MARK: - Tokenizer

    enum Segment: Equatable {
        case text(String)
        case citation(Int)
    }

    static func tokenize(_ input: String) -> [Segment] {
        var segments: [Segment] = []
        var buffer = ""
        var i = input.startIndex
        while i < input.endIndex {
            let ch = input[i]
            if ch == "[", let end = input[i...].firstIndex(of: "]") {
                let raw = input[input.index(after: i)..<end]
                if let n = Int(raw), n > 0 {
                    if !buffer.isEmpty { segments.append(.text(buffer)); buffer = "" }
                    segments.append(.citation(n))
                    i = input.index(after: end)
                    continue
                }
            }
            buffer.append(ch)
            i = input.index(after: i)
        }
        if !buffer.isEmpty { segments.append(.text(buffer)) }
        return segments
    }
}
