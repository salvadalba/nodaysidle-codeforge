import Foundation
import MLX
import MLXLMCommon
import MLXLLM
import OSLog
import Tokenizers

/// Actor responsible for MLX on-device model inference.
///
/// Manages model lifecycle (load/unload), generates text via streaming
/// AsyncStream, and handles memory pressure by unloading the model.
actor InferenceActor {
    private let logger = Logger(subsystem: "com.codeforge.app", category: "inference")

    private var modelContainer: ModelContainer?
    private let promptBuilder: PromptBuilder
    private var unloadTask: Task<Void, Never>?

    /// Whether the model is currently loaded.
    var isLoaded: Bool { modelContainer != nil }

    init() {
        self.promptBuilder = PromptBuilder()
        logger.info("InferenceActor initialized")
    }

    // MARK: - Model Lifecycle

    /// Load the model from Hugging Face hub.
    func loadModel(
        modelID: String = ModelDownloader.defaultModelID,
        progressHandler: (@Sendable (Progress) -> Void)? = nil
    ) async throws {
        cancelUnloadTimer()

        if isLoaded {
            logger.info("Model already loaded")
            return
        }

        logger.info("Loading model: \(modelID)")

        let config = ModelConfiguration(id: modelID)

        let container = try await LLMModelFactory.shared.loadContainer(
            configuration: config,
            progressHandler: progressHandler ?? { _ in }
        )

        self.modelContainer = container
        logger.info("Model loaded successfully")
    }

    /// Unload the model from memory.
    func unloadModel() {
        cancelUnloadTimer()
        modelContainer = nil
        MLX.GPU.clearCache()
        logger.info("Model unloaded")
    }

    /// Schedule model unload after a delay (e.g., when AI panel is collapsed).
    func scheduleUnload(after delay: Duration = .seconds(60)) {
        cancelUnloadTimer()
        unloadTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.unloadModel()
        }
    }

    private func cancelUnloadTimer() {
        unloadTask?.cancel()
        unloadTask = nil
    }

    // MARK: - Generation

    /// Explain the selected code.
    func explain(
        selection: String,
        fileContext: String,
        fileName: String?,
        language: SourceLanguage?,
        cursorPosition: Int
    ) -> AsyncStream<String> {
        let prompt = promptBuilder.buildPrompt(
            type: .explain(selection: selection),
            fileContext: fileContext,
            fileName: fileName,
            language: language,
            cursorPosition: cursorPosition
        )
        return generate(prompt: prompt)
    }

    /// Answer a question about the code.
    func answer(
        question: String,
        fileContext: String,
        fileName: String?,
        language: SourceLanguage?,
        cursorPosition: Int
    ) -> AsyncStream<String> {
        let prompt = promptBuilder.buildPrompt(
            type: .answer(question: question),
            fileContext: fileContext,
            fileName: fileName,
            language: language,
            cursorPosition: cursorPosition
        )
        return generate(prompt: prompt)
    }

    /// Suggest edits based on an instruction.
    func suggestEdit(
        instruction: String,
        fileContext: String,
        fileName: String?,
        language: SourceLanguage?,
        cursorPosition: Int
    ) -> AsyncStream<String> {
        let prompt = promptBuilder.buildPrompt(
            type: .suggestEdit(instruction: instruction),
            fileContext: fileContext,
            fileName: fileName,
            language: language,
            cursorPosition: cursorPosition
        )
        return generate(prompt: prompt)
    }

    /// Core generation method — streams tokens as strings.
    private func generate(prompt: String) -> AsyncStream<String> {
        let container = self.modelContainer
        return AsyncStream { continuation in
            Task {
                guard let container else {
                    continuation.finish()
                    return
                }

                do {
                    try await container.perform { context in
                        let input = try await context.processor.prepare(
                            input: .init(prompt: prompt)
                        )

                        var tokenCount = 0
                        let maxTokens = 2048

                        _ = try MLXLMCommon.generate(
                            input: input,
                            parameters: .init(temperature: 0.7),
                            context: context
                        ) { tokens in
                            let text = context.tokenizer.decode(tokens: tokens)
                            continuation.yield(text)
                            tokenCount = tokens.count

                            if Task.isCancelled || tokenCount >= maxTokens {
                                return .stop
                            }
                            return .more
                        }
                    }
                } catch {
                    // Log but don't crash — generation errors are expected
                }

                continuation.finish()
            }
        }
    }

    // MARK: - Memory Pressure

    /// Handle memory pressure by unloading the model immediately.
    func handleMemoryPressure() {
        unloadModel()
        logger.warning("Model unloaded due to memory pressure")
    }
}
