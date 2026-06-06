import Foundation
import Observation
#if canImport(PDFKit)
import PDFKit
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
        let didStartSecurityScope = url.startAccessingSecurityScopedResource()
        defer {
            if didStartSecurityScope {
                url.stopAccessingSecurityScopedResource()
            }
        }
        do {
            let ext = url.pathExtension.lowercased()
            let title = url.deletingPathExtension().lastPathComponent
            let text: String
            switch ext {
            case "pdf":
                text = try Self.extractPDF(url: url)
            case "md", "markdown", "txt", "rtf", "csv", "json", "yaml", "yml", "html", "htm":
                text = try String(contentsOf: url, encoding: .utf8)
            default:
                if let decoded = try? String(contentsOf: url, encoding: .utf8) {
                    text = decoded
                } else {
                    throw KBError.unsupportedFormat(ext)
                }
            }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw KBError.emptyText(title)
            }
            await ingest(title: title, text: text, source: url.path)
        } catch {
            self.lastError = error.localizedDescription
        }
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

    public enum KBError: Error, LocalizedError {
        case unsupportedFormat(String)
        case emptyText(String)
        public var errorDescription: String? {
            switch self {
            case .unsupportedFormat(let ext):
                "Unsupported file extension: .\(ext). Supported: pdf, md, txt, csv, json, yaml, html."
            case .emptyText(let title):
                "No readable text was found in \(title)."
            }
        }
    }

    #if canImport(PDFKit)
    private static func extractPDF(url: URL) throws -> String {
        guard let doc = PDFDocument(url: url) else {
            throw KBError.unsupportedFormat("pdf")
        }
        var out = ""
        for i in 0..<doc.pageCount {
            if let text = doc.page(at: i)?.string {
                out += text + "\n\n"
            }
        }
        return out
    }
    #else
    private static func extractPDF(url: URL) throws -> String {
        throw KBError.unsupportedFormat("pdf-unavailable")
    }
    #endif
}
