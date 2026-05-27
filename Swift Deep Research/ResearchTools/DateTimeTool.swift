import Foundation

/// Returns the current date/time in the user's locale.
///
/// LLM training cutoffs make this a surprisingly important grounding tool:
/// "what's recent" questions go badly when the model believes it's 2023.
/// The tool always reports the host machine's clock, never an inferred date.
public struct DateTimeTool: ResearchTool {
    public let spec = LLMToolSpec(
        name: "current_datetime",
        description: "Get the current date and time. Use this when the user asks 'recent', 'today', 'this year', or any question whose answer depends on the present date.",
        parametersJSONSchema: #"""
        {
          "type": "object",
          "properties": {
            "timezone": { "type": "string", "description": "IANA timezone identifier, e.g. 'America/Los_Angeles'. Defaults to the host's local time zone." },
            "format": { "type": "string", "enum": ["iso8601", "human"], "default": "human" }
          }
        }
        """#
    )

    public init() {}

    public func call(argumentsJSON: String, context: ToolContext) async throws -> ToolOutcome {
        struct Args: Decodable { let timezone: String?; let format: String? }
        let args = (argumentsJSON.data(using: .utf8).flatMap { try? JSONDecoder().decode(Args.self, from: $0) })
            ?? Args(timezone: nil, format: nil)

        let timezone: TimeZone
        if let id = args.timezone, let tz = TimeZone(identifier: id) {
            timezone = tz
        } else {
            timezone = .current
        }
        let now = Date()
        let formatted: String
        if (args.format ?? "human").lowercased() == "iso8601" {
            let f = ISO8601DateFormatter()
            f.timeZone = timezone
            f.formatOptions = [.withInternetDateTime]
            formatted = f.string(from: now)
        } else {
            let f = DateFormatter()
            f.timeZone = timezone
            f.dateStyle = .full
            f.timeStyle = .long
            formatted = f.string(from: now)
        }

        let weekdayFormatter = DateFormatter()
        weekdayFormatter.timeZone = timezone
        weekdayFormatter.dateFormat = "EEEE"
        let weekday = weekdayFormatter.string(from: now)

        let cal = Calendar(identifier: .iso8601)
        let week = cal.component(.weekOfYear, from: now)
        let year = cal.component(.year, from: now)

        let payload: [String: Any] = [
            "now": formatted,
            "weekday": weekday,
            "iso_week": week,
            "year": year,
            "timezone": timezone.identifier,
            "unix": Int(now.timeIntervalSince1970)
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        return .ok(summary: "Current time: \(formatted) (\(timezone.identifier))",
                   payloadJSON: String(decoding: data, as: UTF8.self))
    }
}
