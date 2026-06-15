import Foundation

/// Helpers for coaxing strict JSON out of LLM completions, which routinely wrap
/// their output in ```json fences or surround it with prose. This was previously
/// copy-pasted four times (Planner, Reflector, DeerFlowEngine, CitationExtractor)
/// with subtle drift; a parsing improvement in one copy never reached the others.
enum LLMJSON {
    /// Strip code fences and return the substring from the first `{` to the last
    /// `}`. Returns the input unchanged when no braces are found, so the caller's
    /// `JSONDecoder` surfaces the real parse error rather than empty input.
    static func extractObject(_ text: String) -> String {
        var s = text
        if s.contains("```") {
            s = s.replacingOccurrences(of: "```json", with: "")
            s = s.replacingOccurrences(of: "```", with: "")
        }
        if let first = s.firstIndex(of: "{"), let last = s.lastIndex(of: "}"), first <= last {
            return String(s[first...last])
        }
        return s
    }

    /// JSON-encode a string as a quoted literal (with surrounding quotes), for
    /// safely interpolating user/query text into a hand-built JSON tool-arguments
    /// string. Falls back to a minimal manual escape if encoding somehow fails.
    static func quoted(_ s: String) -> String {
        if let data = try? JSONEncoder().encode(s), let str = String(data: data, encoding: .utf8) {
            return str
        }
        let escaped = s.replacingOccurrences(of: "\\", with: "\\\\")
                       .replacingOccurrences(of: "\"", with: "\\\"")
                       .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }
}
