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
        if let reason = URLSafety.blockReason(for: url) {
            return .failed(message: "read_pdf: refusing to fetch \(url.absoluteString) — \(reason). Only public http(s) URLs are allowed.")
        }
        guard await context.budget.registerSource(for: context.workerID) else {
            return .failed(message: "Source cap reached for this worker")
        }

        let maxPages = max(1, min(args.maxPages ?? 60, 200))
        let session = self.session
        let fetched: FetchedSource
        let wasCached: Bool
        do {
            (fetched, wasCached) = try await context.cache.fetch(url) { resolved in
                var req = URLRequest(url: resolved)
                req.setValue("application/pdf", forHTTPHeaderField: "Accept")
                req.setValue(HTTPClientCommon.browserUserAgent, forHTTPHeaderField: "User-Agent")
                let (bytes, response) = try await HTTPClientCommon.dataWithRetry(for: req, session: session, label: "read_pdf")
                guard let http = response as? HTTPURLResponse, (200..<300) ~= http.statusCode else {
                    throw EngineFailure(kind: .toolFailure,
                                        message: "read_pdf: HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                }
                // A URL that returns an HTML error page with 200 OK would feed
                // garbage to PDFKit ("not a valid PDF"); detect that early.
                if let mime = http.mimeType?.lowercased(),
                   mime.contains("html") || mime.contains("xml") {
                    throw EngineFailure(kind: .toolFailure,
                                        message: "read_pdf: URL returned \(mime), not a PDF — use fetch_url for HTML pages.")
                }
                return try Self.extract(data: bytes, url: resolved, maxPages: maxPages)
            }
        } catch {
            // Release the reserved source slot so a failed download doesn't
            // shrink this worker's source budget.
            await context.budget.releaseSource(for: context.workerID)
            return .failed(message: "read_pdf failed: \(error.localizedDescription)")
        }
        if wasCached {
            // Cache/in-flight hit: no new download happened, so give back the
            // reserved source slot and skip the token charge (re-charging would
            // double-count), then surface the dedup to the UI.
            await context.budget.releaseSource(for: context.workerID)
            context.emit(.sourceCacheHit(context.workerID, url))
        } else {
            context.emit(.sourceFetched(context.workerID, fetched))
            await context.charge(fetched.extractedText.count / 4)
        }
        let payload = try JSONEncoder().encode(fetched)
        return .ok(summary: "Read PDF: \(fetched.title) (\(fetched.extractedText.count) chars)",
                   payloadJSON: String(decoding: payload, as: UTF8.self))
    }

    #if canImport(PDFKit)
    private static func extract(data: Data, url: URL, maxPages: Int) throws -> FetchedSource {
        guard let doc = PDFDocument(data: data) else {
            throw EngineFailure(kind: .toolFailure, message: "read_pdf: not a valid PDF")
        }
        // Encrypted PDFs decode but yield nil text on every page. Try the empty
        // password (a common "owner-locked but readable" case) and fail clearly
        // otherwise instead of returning a silently empty source.
        if doc.isEncrypted && doc.isLocked {
            if !doc.unlock(withPassword: "") {
                throw EngineFailure(kind: .toolFailure,
                                    message: "read_pdf: PDF is password-protected and could not be opened.")
            }
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
        // A scanned/image-only PDF parses fine but extracts no selectable text;
        // surface that rather than returning an empty "source".
        guard !cleaned.isEmpty else {
            throw EngineFailure(kind: .toolFailure,
                                message: "read_pdf: no extractable text (likely a scanned/image-only PDF).")
        }
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
