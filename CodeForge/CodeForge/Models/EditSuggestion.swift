import Foundation

/// A suggested code edit from the AI agent.
///
/// Contains the original text, its replacement, the byte range in the
/// document, and the model's explanation for the change.
struct EditSuggestion: Codable, Sendable, Equatable, Identifiable {
    let id: UUID
    let startByte: Int
    let endByte: Int
    let original: String
    let replacement: String
    let explanation: String

    init(
        id: UUID = UUID(),
        startByte: Int,
        endByte: Int,
        original: String,
        replacement: String,
        explanation: String
    ) {
        self.id = id
        self.startByte = startByte
        self.endByte = endByte
        self.original = original
        self.replacement = replacement
        self.explanation = explanation
    }

    /// Parse an EditSuggestion from structured model output.
    ///
    /// Expected format:
    /// ```
    /// <<<EDIT
    /// RANGE: startByte-endByte
    /// ORIGINAL:
    /// ...original text...
    /// REPLACEMENT:
    /// ...replacement text...
    /// EXPLANATION: ...
    /// EDIT>>>
    /// ```
    static func parse(from output: String) -> [EditSuggestion] {
        var suggestions: [EditSuggestion] = []
        let blocks = output.components(separatedBy: "<<<EDIT")

        for block in blocks.dropFirst() {
            guard let endIdx = block.range(of: "EDIT>>>") else { continue }
            let content = String(block[block.startIndex..<endIdx.lowerBound])

            guard let range = extractField("RANGE", from: content),
                  let original = extractMultilineField("ORIGINAL", until: "REPLACEMENT", from: content),
                  let replacement = extractMultilineField("REPLACEMENT", until: "EXPLANATION", from: content),
                  let explanation = extractField("EXPLANATION", from: content) else {
                continue
            }

            let rangeParts = range.split(separator: "-").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard rangeParts.count == 2 else { continue }

            suggestions.append(EditSuggestion(
                startByte: rangeParts[0],
                endByte: rangeParts[1],
                original: original.trimmingCharacters(in: .whitespacesAndNewlines),
                replacement: replacement.trimmingCharacters(in: .whitespacesAndNewlines),
                explanation: explanation.trimmingCharacters(in: .whitespacesAndNewlines)
            ))
        }

        return suggestions
    }

    private static func extractField(_ name: String, from content: String) -> String? {
        guard let range = content.range(of: "\(name):") else { return nil }
        let after = content[range.upperBound...]
        let line = after.prefix(while: { $0 != "\n" })
        return String(line).trimmingCharacters(in: .whitespaces)
    }

    private static func extractMultilineField(
        _ name: String,
        until terminator: String,
        from content: String
    ) -> String? {
        guard let start = content.range(of: "\(name):") else { return nil }
        let after = content[start.upperBound...]
        guard let end = after.range(of: "\(terminator):") else {
            return String(after)
        }
        return String(after[after.startIndex..<end.lowerBound])
    }
}
