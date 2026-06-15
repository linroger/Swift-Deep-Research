import Foundation

/// Safe arithmetic expression evaluator using `NSExpression`.
///
/// LLMs are unreliable at multi-step arithmetic. A calculator tool lets the
/// worker delegate "what's 17 × 23 ÷ 0.42" instead of guessing. We restrict
/// input to a whitelist of characters and rely on `NSExpression` to refuse
/// anything it doesn't recognize, so the tool can't accidentally evaluate
/// code paths.
public struct CalculatorTool: ResearchTool {
    public let spec = LLMToolSpec(
        name: "calculator",
        description: "Evaluate a basic arithmetic expression. Supports +, -, *, /, parentheses, exponents (**), sqrt(x), abs(x), log(x), and constants pi/e.",
        parametersJSONSchema: #"""
        {
          "type": "object",
          "required": ["expression"],
          "properties": {
            "expression": { "type": "string", "description": "Arithmetic expression to evaluate, e.g. '(17 * 23) / 0.42'." }
          }
        }
        """#
    )

    public init() {}

    public func call(argumentsJSON: String, context: ToolContext) async throws -> ToolOutcome {
        struct Args: Decodable { let expression: String }
        guard let data = argumentsJSON.data(using: .utf8),
              let args = try? JSONDecoder().decode(Args.self, from: data) else {
            return .failed(message: "calculator: invalid arguments")
        }
        let raw = args.expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return .failed(message: "calculator: empty expression") }

        // Whitelist: digits, basic operators, common symbols, parentheses, named functions.
        let allowed = Set("0123456789.+-*/%(),^ \t\n_eExX")
        let nameSet = CharacterSet.letters
        let cleaned: String = {
            // Normalize a few unicode operators.
            var s = raw
                .replacingOccurrences(of: "×", with: "*")
                .replacingOccurrences(of: "÷", with: "/")
                .replacingOccurrences(of: "−", with: "-")
                .replacingOccurrences(of: "**", with: "^")
            // Substitute named constants before validation, but only as
            // standalone tokens. A naive `replacingOccurrences(of: "e", ...)`
            // corrupts scientific notation (`1e3` would become `1·2.718…·3`)
            // and any identifier containing the letter. Word-boundary regex
            // (`\be\b`) matches the bare constant only: in `1e3` the `e` sits
            // between two word characters, so there is no boundary and it is
            // left untouched for NSExpression to parse as an exponent.
            s = s.replacingOccurrences(of: #"\bpi\b"#,
                                       with: "\(Double.pi)",
                                       options: [.regularExpression, .caseInsensitive])
            s = s.replacingOccurrences(of: #"\be\b"#,
                                       with: "\(M_E)",
                                       options: .regularExpression)
            return s
        }()
        for ch in cleaned where !(allowed.contains(ch) || ch.unicodeScalars.allSatisfy(nameSet.contains)) {
            return .failed(message: "calculator: disallowed character \(ch.debugDescription)")
        }

        // NSExpression understands the four basic operators and **; we map ^ → **.
        let nsForm = cleaned.replacingOccurrences(of: "^", with: "**")
        let expression = NSExpression(format: nsForm)
        let value = expression.expressionValue(with: nil, context: nil)
        guard let number = (value as? NSNumber)?.doubleValue else {
            return .failed(message: "calculator: could not evaluate '\(raw)'")
        }
        if !number.isFinite {
            return .failed(message: "calculator: result is not finite (\(number))")
        }
        let payload: [String: Any] = [
            "expression": raw,
            "result": number
        ]
        let payloadData = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let formatted = (number == number.rounded()) ? String(Int64(number)) : String(number)
        return .ok(summary: "\(raw) = \(formatted)",
                   payloadJSON: String(decoding: payloadData, as: UTF8.self))
    }
}
