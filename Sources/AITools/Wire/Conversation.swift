import Foundation
import PelicanKit

/// A request to a model and its reply, read out of traffic Pelican could see.
///
/// This is what the AI Tools screen shows under "Chats": what was actually sent on your behalf
/// — the system prompt a tool adds, the files and context it attaches, the tool calls it makes
/// — and what came back.
package struct Conversation: Sendable, Hashable {
    package struct Turn: Sendable, Hashable, Identifiable {
        package enum Role: String, Sendable, Codable {
            case system, user, assistant, toolResult, toolCall
            package var label: String {
                switch self {
                case .system: return "system prompt"
                case .user: return "you"
                case .assistant: return "the model"
                case .toolResult: return "tool result"
                case .toolCall: return "tool call"
                }
            }
        }
        package var id = UUID()
        package var role: Role
        package var text: String
        /// For a tool call or result, which tool.
        package var toolName: String?
        /// Attachments, by size rather than content.
        package var attachmentBytes: Int

        package init(role: Role, text: String, toolName: String? = nil, attachmentBytes: Int = 0) {
            self.role = role
            self.text = text
            self.toolName = toolName
            self.attachmentBytes = attachmentBytes
        }
    }

    package var model: String?
    package var turns: [Turn]
    /// What the decoder could not make sense of, so the screen can be honest about it.
    package var partial: Bool
    package var note: String?

    package init(model: String? = nil, turns: [Turn] = [], partial: Bool = false, note: String? = nil) {
        self.model = model
        self.turns = turns
        self.partial = partial
        self.note = note
    }

    package var isEmpty: Bool { turns.isEmpty }

    /// Everything the person's side of the conversation carried, for the detectors to read.
    package var sentText: String {
        turns.filter { $0.role != .assistant }.map(\.text).joined(separator: "\n")
    }
}

/// Turns a captured exchange into a conversation, where it recognises the shape.
///
/// Pure functions over what was read: no network, no state. A body it does not recognise is
/// reported as such rather than guessed at.
package enum ConversationDecoder {

    /// Decode whatever the authority and path suggest.
    package static func decode(_ exchange: InspectedExchange) -> Conversation? {
        let host = exchange.authority.lowercased()
        if host.hasSuffix("anthropic.com") || host.hasSuffix("claude.ai") || host.hasSuffix("claude.com") {
            return anthropic(exchange)
        }
        if host.hasSuffix("openai.com") || host.hasSuffix("chatgpt.com") {
            return openAI(exchange)
        }
        return nil
    }

    // MARK: - Anthropic Messages

    /// The Messages API: a JSON request with `system` and `messages`, and either a JSON reply
    /// or a stream of server-sent events.
    package static func anthropic(_ exchange: InspectedExchange) -> Conversation? {
        guard let request = json(exchange.requestBody.text) else { return nil }
        var conversation = Conversation(model: request["model"] as? String)

        // The system prompt may be a string or a list of blocks.
        if let system = request["system"] as? String, !system.isEmpty {
            conversation.turns.append(.init(role: .system, text: system))
        } else if let blocks = request["system"] as? [[String: Any]] {
            let text = blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
            if !text.isEmpty { conversation.turns.append(.init(role: .system, text: text)) }
        }

        for message in request["messages"] as? [[String: Any]] ?? [] {
            let role = (message["role"] as? String) == "assistant" ? Conversation.Turn.Role.assistant : .user
            conversation.turns += contentTurns(message["content"], defaultRole: role)
        }

        // The reply: streamed events, or one JSON object.
        if exchange.responseBody.contentType?.contains("event-stream") == true
            || exchange.responseBody.text.hasPrefix("event:") {
            let streamed = ServerSentEvents.parse(exchange.responseBody.text)
            let text = anthropicStreamText(streamed)
            if !text.isEmpty { conversation.turns.append(.init(role: .assistant, text: text)) }
            if exchange.responseBody.truncated { conversation.partial = true }
        } else if let reply = json(exchange.responseBody.text) {
            conversation.turns += contentTurns(reply["content"], defaultRole: .assistant)
            if conversation.model == nil { conversation.model = reply["model"] as? String }
        }

        if exchange.requestBody.truncated {
            conversation.partial = true
            conversation.note = "The request was larger than Pelican keeps, so this is the beginning of it."
        }
        return conversation.isEmpty ? nil : conversation
    }

    /// Anthropic's content blocks: text, tool calls, tool results, and attachments.
    private static func contentTurns(_ content: Any?, defaultRole: Conversation.Turn.Role) -> [Conversation.Turn] {
        if let text = content as? String {
            return text.isEmpty ? [] : [.init(role: defaultRole, text: text)]
        }
        guard let blocks = content as? [[String: Any]] else { return [] }
        var out: [Conversation.Turn] = []
        for block in blocks {
            switch block["type"] as? String {
            case "text":
                if let text = block["text"] as? String, !text.isEmpty {
                    out.append(.init(role: defaultRole, text: text))
                }
            case "tool_use":
                let name = block["name"] as? String
                let input = block["input"].map { compactJSON($0) } ?? ""
                out.append(.init(role: .toolCall, text: input, toolName: name))
            case "tool_result":
                let text = contentTurns(block["content"], defaultRole: .toolResult)
                    .map(\.text).joined(separator: "\n")
                out.append(.init(role: .toolResult, text: text,
                                 toolName: block["tool_use_id"] as? String))
            case "image", "document":
                // Never the bytes — just how much was attached.
                let source = block["source"] as? [String: Any]
                let data = (source?["data"] as? String)?.count ?? 0
                out.append(.init(role: defaultRole, text: "(an attachment)", attachmentBytes: data))
            default:
                break
            }
        }
        return out
    }

    /// Reassemble the assistant's text from a Messages stream.
    private static func anthropicStreamText(_ events: [ServerSentEvents.Event]) -> String {
        var text = ""
        for event in events {
            guard let payload = json(event.data) else { continue }
            if let delta = payload["delta"] as? [String: Any] {
                if let piece = delta["text"] as? String { text += piece }
                if let piece = delta["partial_json"] as? String { text += piece }
            }
        }
        return text
    }

    // MARK: - OpenAI

    /// Chat Completions and Responses both carry a list of messages.
    package static func openAI(_ exchange: InspectedExchange) -> Conversation? {
        guard let request = json(exchange.requestBody.text) else { return nil }
        var conversation = Conversation(model: request["model"] as? String)

        let items = (request["messages"] as? [[String: Any]])
            ?? (request["input"] as? [[String: Any]]) ?? []
        for message in items {
            let roleName = message["role"] as? String ?? "user"
            let role: Conversation.Turn.Role
            switch roleName {
            case "system", "developer": role = .system
            case "assistant": role = .assistant
            case "tool": role = .toolResult
            default: role = .user
            }
            if let text = message["content"] as? String, !text.isEmpty {
                conversation.turns.append(.init(role: role, text: text))
            } else if let blocks = message["content"] as? [[String: Any]] {
                for block in blocks {
                    if let text = (block["text"] ?? block["input_text"]) as? String, !text.isEmpty {
                        conversation.turns.append(.init(role: role, text: text))
                    }
                }
            }
        }

        if exchange.responseBody.contentType?.contains("event-stream") == true
            || exchange.responseBody.text.hasPrefix("data:") {
            var text = ""
            for event in ServerSentEvents.parse(exchange.responseBody.text) {
                guard event.data != "[DONE]", let payload = json(event.data) else { continue }
                if let choices = payload["choices"] as? [[String: Any]] {
                    for choice in choices {
                        if let delta = choice["delta"] as? [String: Any],
                           let piece = delta["content"] as? String { text += piece }
                    }
                }
                if let delta = payload["delta"] as? String { text += delta }
            }
            if !text.isEmpty { conversation.turns.append(.init(role: .assistant, text: text)) }
        } else if let reply = json(exchange.responseBody.text) {
            for choice in reply["choices"] as? [[String: Any]] ?? [] {
                if let message = choice["message"] as? [String: Any],
                   let text = message["content"] as? String, !text.isEmpty {
                    conversation.turns.append(.init(role: .assistant, text: text))
                }
            }
        }
        if exchange.requestBody.truncated { conversation.partial = true }
        return conversation.isEmpty ? nil : conversation
    }

    // MARK: - Helpers

    private static func json(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func compactJSON(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(
                  withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return String(describing: value)
        }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Server-sent events, as every streaming model reply uses.
package enum ServerSentEvents {
    package struct Event: Sendable, Hashable {
        package var name: String?
        package var data: String
    }

    /// Parse a stream into its events. A trailing partial event is ignored rather than guessed.
    package static func parse(_ text: String) -> [Event] {
        var out: [Event] = []
        var name: String?
        var data: [String] = []

        func flush() {
            guard !data.isEmpty else { name = nil; return }
            out.append(Event(name: name, data: data.joined(separator: "\n")))
            name = nil
            data = []
        }

        for rawLine in text.replacingOccurrences(of: "\r\n", with: "\n").split(
            separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.isEmpty {
                flush()
            } else if line.hasPrefix(":") {
                continue                                    // a comment or keep-alive
            } else if let colon = line.firstIndex(of: ":") {
                let field = String(line[..<colon])
                var value = String(line[line.index(after: colon)...])
                if value.hasPrefix(" ") { value.removeFirst() }
                if field == "event" { name = value } else if field == "data" { data.append(value) }
            }
        }
        flush()
        return out
    }
}
