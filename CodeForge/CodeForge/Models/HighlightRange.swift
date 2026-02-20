import Foundation

/// A byte range in the source text paired with its syntax token type.
struct HighlightRange: Sendable, Equatable {
    /// Start byte offset in the source (UTF-8).
    let startByte: Int
    /// End byte offset in the source (UTF-8).
    let endByte: Int
    /// The syntax token type for this range.
    let tokenType: TokenType

    var byteCount: Int { endByte - startByte }
}
