import Foundation

/// State of the on-device MLX model.
enum ModelState: Sendable, Equatable {
    case notLoaded
    case downloading(progress: Double)
    case loading
    case loaded
    case error(String)
}

/// Observable model backing the AI agent sidebar.
///
/// Tracks conversation messages, generation state, model lifecycle,
/// streaming text, and pending edit suggestions.
@Observable
final class AIAgentModel: @unchecked Sendable {
    /// Messages in the current conversation.
    var messages: [AIMessage] = []

    /// Whether the model is currently generating a response.
    var isGenerating: Bool = false

    /// Current state of the MLX model.
    var modelState: ModelState = .notLoaded

    /// Text currently being streamed from the model.
    var currentStreamingText: String = ""

    /// Pending edit suggestions from the model.
    var pendingSuggestions: [EditSuggestion] = []

    /// The active conversation ID for persistence.
    var conversationID: UUID?

    /// Whether the AI panel is visible.
    var isPanelVisible: Bool = false

    /// Append a user message and clear streaming state.
    func addUserMessage(_ content: String) {
        let message = AIMessage(
            role: .user,
            content: content,
            timestamp: Date()
        )
        messages.append(message)
        currentStreamingText = ""
    }

    /// Finalize the streaming text into an assistant message.
    func finalizeAssistantMessage() {
        guard !currentStreamingText.isEmpty else { return }
        let message = AIMessage(
            role: .assistant,
            content: currentStreamingText,
            timestamp: Date()
        )
        messages.append(message)
        currentStreamingText = ""
        isGenerating = false
    }

    /// Clear the current conversation.
    func clearConversation() {
        messages = []
        currentStreamingText = ""
        pendingSuggestions = []
        conversationID = nil
    }
}
