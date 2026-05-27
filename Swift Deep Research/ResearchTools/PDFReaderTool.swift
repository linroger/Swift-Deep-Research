import Foundation
#if canImport(PDFKit)
import PDFKit
#endif

/// Download a PDF and extract its text using PDFKit.
///
/// Routes through the shared `SourceCache` so multiple workers researching
/// the same paper only download it once. Caps extracted text at ~40k chars
/// — long enough for most academic papers, short enough that the worker's
/// context window stays usable.
public struct PDFReaderTool: ResearchTool {
    public let spec = LLMToolSpec(
        name: "read_pdf",
        description: "Download a PDF (e.g. an arXiv paper or whitepaper) and extract its full text content.",
        parametersJSONSchema: #"""
        {
          "type": "object",
          "required": ["url"],
          "properties": {
            "url": { "type": "string", "description": "Absolute URL to a PDF file." },
            "maxPages": { "type": "integer", "default": 60, "description": "Stop extracting after N pages (safety cap)." }
          }
        }
        """#
    )

    private let session: URLSession
    public init(session: URLSession = HTTPClientCommon.defaultSession(timeout: 60)) {
        self.session = session
    }

    public func call(argumentsJSON: String, context: ToolContext) async throws -> ToolOutcome {
        struct Args: Decodable { let url: String; let maxPages: Int? }
        guard let data = argumentsJSON.data(using: .utf8),
              let args = try? JSONDecoder().decode(Args.self, from: data) else {
            return .failed(message: "read_pdf: invalid arguments")
        }
        guard let url = URL(string: args.url) else { return .failed(message: "read_pdf: bad URL") }
        guard await context.budget.registerSource(for: context.workerID) else {
            return .failed(message: "Source cap reached for this worker")
        }

        let maxPages = max(1, min(args.maxPages ?? 60, 200))
        let session = self.session
        let fetched: FetchedSource
        do {
            fetched = try await context.cache.fetch(url) { resolved in
                var req = URLRequest(url: resolved)
                req.setValue("application/pdf", forHTTPHeaderField: "Accept")
                let (bytes, response) = try await session.data(for: req)
                guard let http = response as? HTTPURLResponse, (200..<300) ~= http.statusCode else {
                    throw EngineFailure(kind: .toolFailure,
                                        message: "read_pdf: HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                }
                return try Self.extract(data: bytes, url: resolved, maxPages: maxPages)
            }
        } catch {
            return .failed(message: "read_pdf failed: \(error.localizedDescription)")
        }
        context.emit(.sourceFetched(context.workerID, fetched))
        await context.charge(fetched.extractedText.count / 4)
        let payload = try JSONEncoder().encode(fetched)
        return .ok(summary: "Read PDF: \(fetched.title) (\(fetched.extractedText.count) chars)",
                   payloadJSON: String(decoding: payload, as: UTF8.self))
    }

    #if canImport(PDFKit)
    private static func extract(data: Data, url: URL, maxPages: Int) throws -> FetchedSource {
        guard let doc = PDFDocument(data: data) else {
            throw EngineFailure(kind: .toolFailure, message: "read_pdf: not a valid PDF")
        }
        let title: String = {
            if let attr = doc.documentAttributes,
               let t = attr[PDFDocumentAttribute.titleAttribute] as? String,
               !t.trimmingCharacters(in: .whitespaces).isEmpty {
                return t
            }
            return url.lastPathComponent
        }()
        var combined = ""
        let pages = min(doc.pageCount, maxPages)
        for i in 0..<pages {
            guard let page = doc.page(at: i), let text = page.string else { continue }
            combined += text
            combined += "\n\n"
            if combined.count > 60_000 { break }
        }
        let cleaned = combined
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return FetchedSource(id: url.absoluteString,
                             url: url,
                             title: title,
                             extractedText: Clip.clip(cleaned, to: 40_000),
                             strategy: .staticHTML)
    }
    #else
    private static func extract(data: Data, url: URL, maxPages: Int) throws -> FetchedSource {
        throw EngineFailure(kind: .toolFailure, message: "read_pdf: PDFKit unavailable on this platform")
    }
    #endif
}
