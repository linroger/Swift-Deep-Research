import Foundation
import Observation
#if canImport(PDFKit)
import PDFKit
#endif
#if canImport(Vision)
import Vision
import CoreGraphics
#endif

/// View-model for the document library. Wraps a `SeekDBClient` so the UI can
/// list, upload, delete, and search documents stored in the local pyseekdb.
@MainActor
@Observable
public final class KnowledgeBase {
    public var documents: [SeekDBClient.Document] = []
    public var health: Health = .unknown
    public var lastError: String?
    public var isBusy: Bool = false

    private let client: SeekDBClient

    public init(client: SeekDBClient = SeekDBClient()) {
        self.client = client
    }

    public enum Health: Sendable, Equatable {
        case unknown
        case launching                 // process spawned, /health not up yet
        case installing                // building the managed virtualenv (first run)
        case ok(docs: Int, mode: String?)
        case unreachable(String)
    }

    /// Best-effort health check + initial document list. If the sidecar is
    /// offline, ask `SidecarSupervisor` to spawn it (auto-launch) and try
    /// again. Users should never need to run Python manually.
    public func refresh() async {
        // Fast path: sidecar already up.
        if await tryReadHealth() { return }

        // Cold path: ask the supervisor to bring it up, then retry once.
        // `host` is a `let` on the actor → synchronously accessible.
        let host = client.host
        self.health = .launching
        let status = await SidecarSupervisor.shared.ensureRunning(host: host)
        switch status {
        case .running:
            _ = await tryReadHealth()
        case .launching:
            // Process is up but /health hasn't answered yet (cold pyseekdb init
            // can take a bit). Show a friendly "starting…" state, not a failure.
            self.health = .launching
        case .installingDependencies:
            // First run: building the private virtualenv (pip install). This is
            // expected and can take a minute — show progress, not an alarm.
            self.health = .installing
        case .notInstalled(let detail), .failed(let detail):
            self.lastError = detail
            self.health = .unreachable(host.absoluteString)
        case .scriptMissing:
            self.lastError = "Sidecar script missing from app bundle."
            self.health = .unreachable(host.absoluteString)
        }
    }

    /// Read /health + documents; returns false if the sidecar is unreachable.
    @discardableResult
    private func tryReadHealth() async -> Bool {
        do {
            let h = try await client.health()
            self.health = .ok(docs: h.documents ?? 0, mode: h.mode)
            self.documents = try await client.listDocuments()
            self.lastError = nil
            return true
        } catch SeekDBClient.SeekDBError.unreachable(let url) {
            self.health = .unreachable(url.absoluteString)
            self.documents = []
            return false
        } catch {
            self.lastError = error.localizedDescription
            return false
        }
    }

    public func ingest(title: String, text: String, source: String? = nil) async {
        isBusy = true
        defer { isBusy = false }
        do {
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw KBError.emptyText(title.isEmpty ? "Untitled document" : title)
            }
            var meta: [String: String] = [:]
            if let source { meta["source"] = source }
            _ = try await client.upsert(title: title, text: text, metadata: meta.isEmpty ? nil : meta)
            await refresh()
        } catch {
            self.lastError = error.localizedDescription
        }
    }

    /// Ingest a file on disk. Picks the right extractor by extension.
    public func ingestFile(at url: URL) async {
        isBusy = true
        defer { isBusy = false }
        do {
            let extracted = try await Self.extractFile(at: url)
            await ingest(title: extracted.title, text: extracted.text, source: url.path)
        } catch {
            self.lastError = error.localizedDescription
        }
    }

    /// Ingest several files in one batched round-trip. Each file is extracted to
    /// text, then all of them are upserted via the sidecar's `/documents/bulk`
    /// endpoint — one request instead of N — and the document list refreshes once
    /// at the end (kb-bulk-endpoint-unused). Files that fail extraction are
    /// skipped with their error recorded in `lastError`; if the bulk endpoint is
    /// unavailable (older sidecar) or errors, this falls back to the existing
    /// single-add loop so ingestion still succeeds.
    public func ingestFiles(at urls: [URL]) async {
        guard !urls.isEmpty else { return }
        // A single file has no batching to gain; reuse the simpler path so its
        // per-file error semantics (and the security-scope handling) stay intact.
        guard urls.count > 1 else { await ingestFile(at: urls[0]); return }

        isBusy = true
        defer { isBusy = false }

        // Extract every file up front, collecting the (document, source) pairs we
        // can ingest. Extraction failures don't abort the batch — they're noted
        // and the readable files still go through.
        var documents: [SeekDBClient.BulkDocument] = []
        var failures: [String] = []
        for url in urls {
            do {
                let extracted = try await Self.extractFile(at: url)
                documents.append(SeekDBClient.BulkDocument(title: extracted.title,
                                                           text: extracted.text,
                                                           metadata: ["source": url.path]))
            } catch {
                failures.append(error.localizedDescription)
            }
        }

        guard !documents.isEmpty else {
            self.lastError = failures.first ?? "No readable files to ingest."
            return
        }

        do {
            _ = try await client.upsertBulk(documents)
            self.lastError = failures.first   // surface extraction skips, if any
            await refresh()
        } catch {
            // Bulk endpoint missing (older sidecar) or the batched call errored —
            // degrade to single-add so the import still completes. Each document
            // keeps its origin path via the metadata it already carries.
            for doc in documents {
                do {
                    _ = try await client.upsert(title: doc.title,
                                                text: doc.text,
                                                metadata: doc.metadata)
                } catch {
                    failures.append(error.localizedDescription)
                }
            }
            self.lastError = failures.first
            await refresh()
        }
    }

    /// Extracted document text plus a display title, ready for ingestion.
    private struct ExtractedDocument: Sendable {
        let title: String
        let text: String
    }

    /// Read a file on disk and return its extracted text + title, picking the
    /// right extractor by extension. Manages the file's security scope and
    /// enforces the non-empty guard, throwing a typed `KBError` on failure so
    /// both the single- and batched-ingest paths share identical behavior.
    private static func extractFile(at url: URL) async throws -> ExtractedDocument {
        let didStartSecurityScope = url.startAccessingSecurityScopedResource()
        defer {
            if didStartSecurityScope {
                url.stopAccessingSecurityScopedResource()
            }
        }
        let ext = url.pathExtension.lowercased()
        let title = url.deletingPathExtension().lastPathComponent
        let text: String
        switch ext {
        case "pdf":
            text = try await extractPDF(url: url)
        case "md", "markdown", "txt", "rtf", "csv", "json", "yaml", "yml", "html", "htm":
            text = try decodeText(at: url)
        default:
            if let decoded = try? decodeText(at: url) {
                text = decoded
            } else {
                throw KBError.unsupportedFormat(ext)
            }
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw KBError.emptyText(title)
        }
        return ExtractedDocument(title: title, text: text)
    }

    public func delete(id: String) async {
        do {
            try await client.delete(id: id)
            await refresh()
        } catch {
            self.lastError = error.localizedDescription
        }
    }

    public func reset() async {
        do {
            try await client.reset()
            await refresh()
        } catch {
            self.lastError = error.localizedDescription
        }
    }

    public func search(_ query: String, k: Int = 6) async -> [SeekDBClient.QueryHit] {
        (try? await client.query(query, k: k)) ?? []
    }

    public var clientRef: SeekDBClient { client }

    public enum KBError: Error, LocalizedError, Sendable {
        case unsupportedFormat(String)
        case emptyText(String)
        /// The PDF carries no embedded text and OCR found no recognizable text
        /// either — i.e. it's a scanned/image-only document with no legible
        /// content (kb-pdf-no-ocr-no-error-on-empty-pages). Distinct from the
        /// generic `emptyText` so the user gets an actionable diagnosis.
        case scannedPDFNoText(String)
        public var errorDescription: String? {
            switch self {
            case .unsupportedFormat(let ext):
                "Unsupported file extension: .\(ext). Supported: pdf, md, txt, csv, json, yaml, html."
            case .emptyText(let title):
                "No readable text was found in \(title)."
            case .scannedPDFNoText(let title):
                "\(title) appears to be a scanned or image-only PDF: it has no embedded text, " +
                "and OCR found no recognizable text either. Re-scan it with text recognition " +
                "enabled, or supply a text-based PDF."
            }
        }
    }

    /// Decode a text file tolerantly. `String(contentsOf:encoding:.utf8)` throws
    /// on any non-UTF-8 file (Windows-1252, ISO-8859-1, GB2312, UTF-16 …), so a
    /// perfectly readable document in another encoding failed to ingest
    /// (kb-utf8-only-text-load). Prefer Foundation's auto-detection (BOM / file
    /// attributes) via `usedEncoding:`, then fall back through UTF-8,
    /// Windows-1252, and finally ISO-Latin-1 (which never fails) so the file
    /// still ingests instead of erroring.
    private static func decodeText(at url: URL) throws -> String {
        var used: String.Encoding = .utf8
        if let s = try? String(contentsOf: url, usedEncoding: &used) { return s }
        let data = try Data(contentsOf: url)
        for enc: String.Encoding in [.utf8, .utf16, .windowsCP1252, .isoLatin1] {
            if let s = String(data: data, encoding: enc) { return s }
        }
        // .isoLatin1 above maps every byte, so this is effectively unreachable;
        // kept as an explicit, typed failure rather than a force-unwrap.
        throw KBError.unsupportedFormat(url.pathExtension.lowercased())
    }

    #if canImport(PDFKit)
    /// Maximum number of pages we run OCR over. OCR is far slower than embedded
    /// text extraction (each page renders to a bitmap and runs Vision), so we cap
    /// it to keep a pathological scanned PDF from stalling ingestion for minutes.
    /// `nonisolated` so the off-main-actor extraction task can read it.
    private nonisolated static let ocrPageCap = 50

    /// A page is "near-empty" when its extracted text has fewer than this many
    /// non-whitespace characters — typical for image-only pages that PDFKit
    /// reports as a stray ligature or page number rather than real content.
    /// `nonisolated` so the off-main-actor extraction task can read it.
    private nonisolated static let nearEmptyCharThreshold = 16

    private static func extractPDF(url: URL) async throws -> String {
        // All PDFKit work runs off the main actor: text extraction can be slow on
        // large documents and `PDFDocument`/`PDFPage` are non-Sendable, so we keep
        // them local to one detached task and only hand back the (Sendable) result.
        let result = await Task.detached(priority: .userInitiated) {
            () -> Result<String, KBError> in
            guard let doc = PDFDocument(url: url) else {
                return .failure(.unsupportedFormat("pdf"))
            }
            var out = ""
            for i in 0..<doc.pageCount {
                if let text = doc.page(at: i)?.string {
                    out += text + "\n\n"
                }
            }
            // Embedded text present → done. Scanned/image-only PDFs leave `out`
            // empty (or near-empty: a stray page number / ligature), so fall back
            // to OCR (kb-pdf-no-ocr-no-error-on-empty-pages).
            let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count >= Self.nearEmptyCharThreshold { return .success(out) }

            let title = url.deletingPathExtension().lastPathComponent
            let ocrText = Self.ocrPDF(doc: doc, pageCap: Self.ocrPageCap)
            if !ocrText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .success(ocrText)
            }
            // No embedded text AND OCR found nothing → a genuinely scanned/
            // image-only PDF with no legible content. Report that distinctly,
            // not the generic "no readable text" message.
            return .failure(.scannedPDFNoText(title))
        }.value
        return try result.get()
    }

    #if canImport(Vision)
    /// Best-effort OCR over the PDF's pages using Vision. Called from the detached
    /// task that already owns `doc` (rendering + recognition are CPU/GPU-heavy and
    /// must stay off the main actor); the non-Sendable `PDFDocument` never leaves
    /// that task. Returns the concatenated recognized text (possibly empty).
    private nonisolated static func ocrPDF(doc: PDFDocument, pageCap: Int) -> String {
        let pageCount = min(doc.pageCount, pageCap)
        var recognized = ""
        for i in 0..<pageCount {
            guard let page = doc.page(at: i),
                  let cgImage = renderPageToCGImage(page) else { continue }
            if let text = recognizeText(in: cgImage), !text.isEmpty {
                recognized += text + "\n\n"
            }
        }
        return recognized
    }

    /// Render a PDF page to a CGImage at ~2x for legible OCR. Returns nil if the
    /// page has a zero-size bounds or the bitmap context can't be created.
    private nonisolated static func renderPageToCGImage(_ page: PDFPage) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        // 2x scale lifts small scanned type above Vision's recognition floor
        // without ballooning memory on large pages.
        let scale: CGFloat = 2
        let pixelsWide = Int((bounds.width * scale).rounded())
        let pixelsHigh = Int((bounds.height * scale).rounded())
        guard pixelsWide > 0, pixelsHigh > 0 else { return nil }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: pixelsWide,
            height: pixelsHigh,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        // White background — scanned pages are usually dark text on white, and a
        // transparent/black backdrop hurts contrast for recognition.
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: pixelsWide, height: pixelsHigh))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -bounds.origin.x, y: -bounds.origin.y)
        page.draw(with: .mediaBox, to: context)
        return context.makeImage()
    }

    /// Run a synchronous Vision text-recognition request over one rendered page.
    /// Uses accurate recognition with language correction for prose-quality OCR.
    private nonisolated static func recognizeText(in image: CGImage) -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let observations = request.results else { return nil }
        let lines = observations.compactMap { $0.topCandidates(1).first?.string }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
    #else
    /// Vision unavailable at build time → no OCR fallback; caller then reports the
    /// scanned-PDF error if there was no embedded text.
    private nonisolated static func ocrPDF(doc: PDFDocument, pageCap: Int) -> String { "" }
    #endif

    #else
    private static func extractPDF(url: URL) async throws -> String {
        throw KBError.unsupportedFormat("pdf-unavailable")
    }
    #endif
}
