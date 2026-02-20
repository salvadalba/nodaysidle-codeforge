import Foundation

/// A single message in an AI conversation.
/// Codable Sendable struct (NOT a SwiftData @Model).
/// Stored as an encrypted JSON blob inside AIConversation.encryptedMessages.
struct AIMessage: Codable, Sendable, Equatable {
    enum Role: String, Codable, Sendable {
        case user
        case assistant
        case system
    }

    let role: Role
    let content: String
    let timestamp: Date
}
