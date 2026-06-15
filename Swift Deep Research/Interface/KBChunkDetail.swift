import SwiftUI
import AppKit

/// Relevance-score chip for a knowledge-base chunk (0…1, higher = closer match).
/// Shared by the inspector source list and the final answer's source list.
struct KBScoreBadge: View {
    let score: Double?
    var body: some View {
        if let score {
            Text(String(format: "%.0f%%", max(0, min(score, 1)) * 100))
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(tint.opacity(0.18), in: Capsule())
                .foregroundStyle(tint)
        }
    }
    private var tint: Color {
        switch score ?? 0 {
        case 0.6...: .green
        case 0.4..<0.6: .orange
        default: .secondary
        }
    }
}

/// Full-text reader for a single knowledge-base chunk. `kb://` URLs have no
/// browser handler, so tapping a KB source opens this sheet instead of a page.
struct KBChunkDetail: View {
    let source: FetchedSource
    @Environment(\.dismiss) private var dismiss

    private var documentID: String {
        // kb://<doc>/<chunk> — show the decoded document component.
        (source.url.host?.removingPercentEncoding) ?? source.url.host ?? source.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "text.book.closed.fill")
                    .font(.title2)
                    .foregroundStyle(.indigo)
                VStack(alignment: .leading, spacing: 2) {
                    Text(source.title).font(.headline)
                    HStack(spacing: 6) {
                        Text("Knowledge base").font(.caption).foregroundStyle(.secondary)
                        KBScoreBadge(score: source.relevanceScore)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 12)
            Divider()
            ScrollView {
                Text(source.extractedText)
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
            Divider()
            HStack(spacing: 10) {
                Label(documentID, systemImage: "doc.text")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(source.extractedText, forType: .string)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .controlSize(.small)
                .accessibilityLabel("Copy chunk text")
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(width: 560, height: 460)
    }
}
