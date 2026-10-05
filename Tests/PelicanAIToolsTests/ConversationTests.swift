import Foundation
import Testing
@testable import PelicanAITools
@testable import PelicanKit

// MARK: - Fixtures

private func exchange(authority: String, request: String, response: String,
                      responseType: String = "application/json",
                      requestTruncated: Bool = false) -> InspectedExchange {
    InspectedExchange(
        id: "x", startedAt: Date(), source: .manualProxy, state: .complete,
        originName: "claude", pid: 1, toolID: "claude",
        method: "POST", authority: authority, path: "/v1/messages",
        requestBody: .init(text: request, wireByteCount: UInt64(request.utf8.count),
                           truncated: requestTruncated, contentType: "application/json"),
        responseStatus: 200,
        responseBody: .init(text: response, wireByteCount: UInt64(response.utf8.count),
                            contentType: responseType))
}

@Suite struct ServerSentEventsTests {

    @Test func parsesNamedEventsAndMultiLineData() {
        let stream = """
        event: message_start
        data: {"type":"message_start"}

        : a keep-alive comment

        event: content_block_delta
        data: {"a":1}
        data: {"b":2}

        """
        let events = ServerSentEvents.parse(stream)
        #expect(events.count == 2)
        #expect(events.first?.name == "message_start")
        #expect(events.last?.data == "{\"a\":1}\n{\"b\":2}")
    }

    @Test func aTrailingPartialEventIsIgnoredNotGuessed() {
        let events = ServerSentEvents.parse("data: {\"ok\":1}\n\nevent: half")
        #expect(events.count == 1)
        #expect(events.first?.data == "{\"ok\":1}")
    }

    @Test func handlesCarriageReturnsAndEmptyInput() {
        #expect(ServerSentEvents.parse("data: x\r\n\r\n").first?.data == "x")
        #expect(ServerSentEvents.parse("").isEmpty)
    }
}

@Suite struct ConversationDecoderTests {

    @Test func readsAnAnthropicRequestIntoItsTurns() throws {
        let request = """
        {"model":"claude-opus-4-5","system":"You are a helpful assistant.",
         "messages":[
           {"role":"user","content":"What is in my config file?"},
           {"role":"assistant","content":[{"type":"tool_use","name":"Read","input":{"path":"/etc/hosts"}}]},
           {"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":[{"type":"text","text":"127.0.0.1 localhost"}]}]}
         ]}
        """
        let conversation = try #require(ConversationDecoder.decode(
            exchange(authority: "api.anthropic.com", request: request,
                     response: #"{"model":"claude-opus-4-5","content":[{"type":"text","text":"It maps localhost."}]}"#)))
        #expect(conversation.model == "claude-opus-4-5")
        #expect(conversation.turns.map(\.role) == [.system, .user, .toolCall, .toolResult, .assistant])
        #expect(conversation.turns[0].text == "You are a helpful assistant.")
        #expect(conversation.turns[2].toolName == "Read")
        #expect(conversation.turns[2].text.contains("/etc/hosts"))
        #expect(conversation.turns[3].text == "127.0.0.1 localhost")
        #expect(conversation.turns[4].text == "It maps localhost.")
    }

    @Test func reassemblesAStreamedReply() throws {
        let stream = """
        event: content_block_delta
        data: {"delta":{"text":"Hello"}}

        event: content_block_delta
        data: {"delta":{"text":", world"}}

        event: message_stop
        data: {"type":"message_stop"}

        """
        let conversation = try #require(ConversationDecoder.decode(
            exchange(authority: "api.anthropic.com",
                     request: #"{"model":"m","messages":[{"role":"user","content":"hi"}]}"#,
                     response: stream, responseType: "text/event-stream")))
        #expect(conversation.turns.last?.role == .assistant)
        #expect(conversation.turns.last?.text == "Hello, world")
    }

    @Test func attachmentsAreCountedNeverCopied() throws {
        let request = """
        {"model":"m","messages":[{"role":"user","content":[
          {"type":"text","text":"what is this"},
          {"type":"image","source":{"type":"base64","data":"QUJDREVGR0g="}}]}]}
        """
        let conversation = try #require(ConversationDecoder.decode(
            exchange(authority: "api.anthropic.com", request: request, response: "{}")))
        let attachment = try #require(conversation.turns.first { $0.attachmentBytes > 0 })
        #expect(attachment.text == "(an attachment)")
        #expect(attachment.attachmentBytes == 12)
        // The bytes themselves are not carried anywhere.
        #expect(!conversation.turns.contains { $0.text.contains("QUJDREVG") })
    }

    @Test func aTruncatedRequestSaysSoRatherThanLookingComplete() throws {
        let conversation = try #require(ConversationDecoder.decode(
            exchange(authority: "api.anthropic.com",
                     request: #"{"model":"m","messages":[{"role":"user","content":"hi"}]}"#,
                     response: "{}", requestTruncated: true)))
        #expect(conversation.partial)
        #expect(conversation.note?.contains("larger than Pelican keeps") == true)
    }

    @Test func readsAnOpenAIChatAndItsStream() throws {
        let request = """
        {"model":"gpt-5","messages":[
          {"role":"system","content":"Be brief."},
          {"role":"user","content":"Hi"}]}
        """
        let stream = """
        data: {"choices":[{"delta":{"content":"Hey"}}]}

        data: {"choices":[{"delta":{"content":" there"}}]}

        data: [DONE]

        """
        let conversation = try #require(ConversationDecoder.decode(
            exchange(authority: "api.openai.com", request: request, response: stream,
                     responseType: "text/event-stream")))
        #expect(conversation.model == "gpt-5")
        #expect(conversation.turns.map(\.role) == [.system, .user, .assistant])
        #expect(conversation.turns.last?.text == "Hey there")
    }

    @Test func whatTheConversationSentIsWhatTheDetectorsRead() throws {
        let request = """
        {"model":"m","messages":[{"role":"user","content":"my email is ada@example.org"}]}
        """
        let conversation = try #require(ConversationDecoder.decode(
            exchange(authority: "api.anthropic.com", request: request,
                     response: #"{"content":[{"type":"text","text":"noted"}]}"#)))
        // The model's own words are not part of what left this Mac.
        #expect(conversation.sentText.contains("ada@example.org"))
        #expect(!conversation.sentText.contains("noted"))
    }

    @Test func somethingUnrecognisedIsReportedRatherThanInvented() {
        #expect(ConversationDecoder.decode(
            exchange(authority: "api2.cursor.sh", request: "\u{1}\u{2}binary", response: "")) == nil)
        #expect(ConversationDecoder.decode(
            exchange(authority: "api.anthropic.com", request: "not json", response: "{}")) == nil)
    }
}
