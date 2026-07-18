import Foundation
import MLXLLM
import MLXLMCommon

/// A streaming session against an on-device MLX model (port of Fleet's
/// ChatSession, minus the LoRA branch).
///
/// An `actor`, so the non-`Sendable` `ModelContext` it holds never escapes.
actor LLMSession {

    private let modelId: String
    private var context: ModelContext?

    init(modelId: String) {
        self.modelId = modelId
    }

    /// Load the model ahead of the first prompt.
    func warmup() async throws {
        _ = try await loadedContext()
    }

    /// Stream the model's reply to a system + user prompt pair.
    func reply(system: String, user: String, maxTokens: Int = 1024) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let ctx = try await loadedContext()
                    let messages: [Chat.Message] = [.system(system), .user(user)]
                    let input = try await ctx.processor.prepare(input: UserInput(chat: messages))
                    let stream = try MLXLMCommon.generate(
                        input: input,
                        parameters: GenerateParameters(maxTokens: maxTokens, temperature: 0.2),
                        context: ctx
                    )
                    for await item in stream {
                        if Task.isCancelled { break }
                        if case .chunk(let text) = item {
                            continuation.yield(text)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func loadedContext() async throws -> ModelContext {
        if let context { return context }
        let ctx = try await loadModel(id: modelId)
        context = ctx
        return ctx
    }
}
