import Foundation

/// Shared HTTP error-handling primitives for the REST provider clients.
///
/// Every provider that streams over HTTP (Anthropic, Gemini, Ollama, and the
/// OpenAI-compatible family) faces the same two mechanical chores when a
/// non-2xx response arrives: drain a bounded prefix of the error body, and pull
/// a human-readable message out of the (provider-shaped) JSON payload. That
/// mechanical logic used to be copy-pasted three to four times, which is how
/// the per-provider error-handling defects diverged. This type owns the
/// genuinely-common pieces; each client still composes its own final
/// `EngineFailure` so provider-specific message wording (and the
/// `RetryPolicy.isTransient` phrases it must satisfy) is preserved exactly.
///
/// What is centralized:
///   - `drainBody` — bounded raw-byte read from a streaming response.
///   - `parseJSONObject` + the `…Message` field accessors — the shared
///     `{"error":{"message":…}}` / `{"error":"…"}` / `{"message":…}` lookups.
///   - `openAICompatError` — the rich status→guidance mapper, which is the
///     canonical (and only) place that maps 401/402/403/404/422/429/5xx to
///     actionable text.
///
/// What is intentionally NOT flattened: each provider's outward message format
/// (`"Anthropic HTTP 503: overloaded"`, `"Ollama HTTP 404 — model not found"`,
/// the OpenAI-compatible `"<provider>: rate limited (HTTP 429). …"`). Those are
/// distinct on purpose and remain in their respective clients.
enum HTTPErrorMapping {

    // MARK: - Body draining

    /// Read at most `cap` raw bytes from a streaming response body.
    ///
    /// Bounds the read by a raw-byte budget rather than by newlines: a gateway
    /// that returns an error payload with no `\n` would otherwise stall a
    /// line-oriented reader until the inactivity timeout. The byte cap matches
    /// each call site's previous hand-rolled loop exactly.
    ///
    /// - Parameter bestEffort: when `true`, a mid-read transport error is
    ///   swallowed and whatever bytes accumulated so far are returned (the
    ///   caller then falls back to a status-only message). When `false`
    ///   (default) the error propagates so the caller's retry/error path runs.
    static func drainBody(from bytes: URLSession.AsyncBytes,
                          cap: Int,
                          bestEffort: Bool = false) async throws -> Data {
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count >= cap { break }
            }
        } catch {
            if !bestEffort { throw error }
        }
        return data
    }

    // MARK: - JSON error-body extraction

    /// Parse an error body into a top-level JSON object, or `nil` when the body
    /// isn't a JSON object (e.g. an HTML error page or a bare string).
    static func parseJSONObject(from data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// `{"error":{"message":"…"}}` — the nested form OpenAI-compatible servers
    /// and Anthropic both use. Returns a non-empty message or `nil`.
    static func nestedErrorMessage(in obj: [String: Any]) -> String? {
        guard let err = obj["error"] as? [String: Any],
              let msg = err["message"] as? String, !msg.isEmpty else { return nil }
        return msg
    }

    /// `{"error":"…"}` — some gateways put a bare string under `error`.
    static func errorString(in obj: [String: Any]) -> String? {
        guard let err = obj["error"] as? String, !err.isEmpty else { return nil }
        return err
    }

    /// `{"message":"…"}` — a top-level message with no `error` wrapper.
    static func topLevelMessage(in obj: [String: Any]) -> String? {
        guard let msg = obj["message"] as? String, !msg.isEmpty else { return nil }
        return msg
    }

    /// A trimmed, length-limited prefix of the raw body, used as a last resort
    /// when the payload isn't the expected JSON shape (e.g. an HTML 502 page).
    static func rawTextPrefix(from data: Data, limit: Int) -> String? {
        let raw = String(data: data.prefix(limit), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (raw?.isEmpty == false) ? raw : nil
    }

    /// Pull a human message out of an OpenAI-compatible error body, trying the
    /// nested form, then a bare `error` string, then a top-level `message`.
    /// This is exactly the precedence the OpenAI-compatible client used inline.
    static func openAICompatErrorMessage(from body: String) -> String? {
        guard let data = body.data(using: .utf8),
              let obj = parseJSONObject(from: data) else { return nil }
        return nestedErrorMessage(in: obj) ?? errorString(in: obj) ?? topLevelMessage(in: obj)
    }

    // MARK: - Status → guidance mapping (OpenAI-compatible family)

    /// Turn a non-2xx HTTP response into an actionable `EngineFailure` for the
    /// OpenAI-compatible providers. Extracts the provider's own error message
    /// from the JSON body and maps common status codes to plain-language
    /// guidance so a bare "HTTP 402" becomes "payment required — account balance
    /// is likely empty."
    ///
    /// The produced messages are worded so `RetryPolicy.isTransient` continues
    /// to classify them correctly: 429 carries "rate limited (HTTP 429)" and
    /// 5xx carries "(HTTP 5xx)", both of which the policy's transient matcher
    /// keys on. Do not reword these without re-checking that classifier.
    static func openAICompatError(status: Int, body: String, provider: String) -> EngineFailure {
        let detail = openAICompatErrorMessage(from: body)
        let suffix = detail.map { " — \($0)" } ?? ""
        let kind: EngineFailure.Kind
        let message: String
        switch status {
        case 401, 403:
            kind = .configurationMissing
            message = "\(provider): authentication failed (HTTP \(status)). Check the API key in Settings → API keys.\(suffix)"
        case 402:
            kind = .configurationMissing
            message = "\(provider): payment required (HTTP 402). Your account balance is likely empty — add credit, or switch to another provider in Settings.\(suffix)"
        case 429:
            kind = .providerFailure
            message = "\(provider): rate limited (HTTP 429). Slow down or check your plan's limits.\(suffix)"
        case 404:
            kind = .providerFailure
            message = "\(provider): not found (HTTP 404). The model id may be wrong for this endpoint.\(suffix)"
        case 400, 422:
            kind = .providerFailure
            message = "\(provider): request rejected (HTTP \(status)). The model may not support tools, or the model id is invalid.\(suffix)"
        case 500...599:
            kind = .providerFailure
            message = "\(provider): server error (HTTP \(status)). Try again shortly.\(suffix)"
        default:
            kind = .providerFailure
            message = "\(provider): HTTP \(status).\(suffix)"
        }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return EngineFailure(kind: kind, message: message,
                             underlying: trimmed.isEmpty ? nil : String(trimmed.prefix(600)))
    }
}
