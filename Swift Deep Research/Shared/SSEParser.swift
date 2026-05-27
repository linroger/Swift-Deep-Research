import Foundation

/// Minimal SSE (server-sent events) splitter for `text/event-stream` bodies.
///
/// Used by Anthropic, OpenAI, and Gemini streaming providers. Yields raw event
/// payloads — caller parses the JSON. Handles UTF-8 boundaries by buffering
/// partial lines across chunks.
public struct SSEParser: Sendable {
    public struct Event: Sendable, Equatable {
        public var name: String?
        public var data: String
        public init(name: String? = nil, data: String) { self.name = name; self.data = data }
    }

    /// Convert an `AsyncSequence` of `Data` chunks (e.g. `URLSession.bytes`) into events.
    public static func stream<S: AsyncSequence & Sendable>(
        _ bytes: S
    ) -> AsyncThrowingStream<Event, Error> where S.Element == UInt8 {
        AsyncThrowingStream { continuation in
            let task = Task {
                var lineBuffer = Data()
                var current = Event(data: "")
                var hasData = false
                do {
                    for try await byte in bytes {
                        if byte == 0x0A { // newline
                            let line = String(decoding: lineBuffer, as: UTF8.self)
                            lineBuffer.removeAll(keepingCapacity: true)
                            if line.isEmpty {
                                if hasData {
                                    continuation.yield(current)
                                    current = Event(data: "")
                                    hasData = false
                                }
                                continue
                            }
                            if line.hasPrefix(":") { continue }   // comment
                            if let colon = line.firstIndex(of: ":") {
                                let field = String(line[..<colon])
                                var value = String(line[line.index(after: colon)...])
                                if value.hasPrefix(" ") { value.removeFirst() }
                                switch field {
                                case "event": current.name = value
                                case "data":
                                    if hasData { current.data += "\n" }
                                    current.data += value
                                    hasData = true
                                default: break
                                }
                            }
                        } else {
                            lineBuffer.append(byte)
                        }
                    }
                    if hasData { continuation.yield(current) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
