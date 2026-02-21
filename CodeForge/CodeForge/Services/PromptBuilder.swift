import Foundation
import OSLog

/// Builds prompts for the AI agent with file context truncation.
///
/// Constructs system prompt + truncated file context + user query,
/// fitting within the model's context window. Escapes potential
/// prompt injection markers in user-provided content.
nonisolated struct PromptBuilder: Sendable {
    private static let logger = Logger(subsystem: "com.codeforge.app", category: "inference")

    /// Approximate max characters for file context (leaves room for system prompt + response).
    /// Assumes ~4 chars per token, targeting ~3K tokens of context.
    static let defaultContextBudget = 12_000

    private let contextBudget: Int

    init(contextBudget: Int = defaultContextBudget) {
        self.contextBudget = contextBudget
    }

    // MARK: - Prompt Types

    nonisolated enum PromptType: Sendable {
        case explain(selection: String)
        case answer(question: String)
        case suggestEdit(instruction: String)
    }

    // MARK: - Build Prompt

    /// Build a complete prompt with system context, file context, and user query.
    func buildPrompt(
        type: PromptType,
        fileContext: String,
        fileName: String?,
        language: SourceLanguage?,
        cursorPosition: Int
    ) -> String {
        let systemPrompt = buildSystemPrompt(language: language)
        let truncatedContext = truncateContext(
            fileContext,
            centerByte: cursorPosition,
            budget: contextBudget
        )
        let escapedContext = escapeInjectionMarkers(truncatedContext)
        let userQuery = buildUserQuery(type: type)

        let fileNameStr = fileName ?? "untitled"
        let langStr = language?.rawValue ?? "unknown"

        return """
        \(systemPrompt)

        --- FILE: \(fileNameStr) (\(langStr)) ---
        \(escapedContext)
        --- END FILE ---

        \(userQuery)
        """
    }

    // MARK: - System Prompt

    private func buildSystemPrompt(language: SourceLanguage?) -> String {
        let langHint = language.map { "The user is working in \($0.rawValue)." } ?? ""
        return """
        You are CodeForge AI, a code assistant running locally on-device. \
        You help with code explanation, answering programming questions, \
        and suggesting edits. Be concise and precise. \(langHint)
        """
    }

    // MARK: - User Query

    private func buildUserQuery(type: PromptType) -> String {
        switch type {
        case .explain(let selection):
            return """
            Explain the following code selection clearly and concisely:

            ```
            \(escapeInjectionMarkers(selection))
            ```
            """

        case .answer(let question):
            return "Question: \(escapeInjectionMarkers(question))"

        case .suggestEdit(let instruction):
            return """
            Suggest code edits based on this instruction: \(escapeInjectionMarkers(instruction))

            Format each edit as:
            <<<EDIT
            RANGE: startByte-endByte
            ORIGINAL:
            (the original code)
            REPLACEMENT:
            (the replacement code)
            EXPLANATION: (brief explanation)
            EDIT>>>
            """
        }
    }

    // MARK: - Context Truncation

    /// Truncate file content using a sliding window centered on the cursor.
    ///
    /// - Parameters:
    ///   - content: Full file content.
    ///   - centerByte: Byte offset to center the window on.
    ///   - budget: Maximum character budget for the context window.
    /// - Returns: Truncated content with line-aligned boundaries.
    func truncateContext(
        _ content: String,
        centerByte: Int,
        budget: Int
    ) -> String {
        // M6 fix: use utf8 byte count consistently (budget is byte-based)
        guard content.utf8.count > budget else { return content }

        let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard !lines.isEmpty else { return content }

        // Find the line containing the center byte
        var byteOffset = 0
        var centerLine = 0
        for (i, line) in lines.enumerated() {
            let lineBytes = line.utf8.count + 1 // +1 for newline
            if byteOffset + lineBytes > centerByte {
                centerLine = i
                break
            }
            byteOffset += lineBytes
        }

        // Expand window from center until budget is reached
        var start = centerLine
        var end = centerLine
        var currentSize = lines[centerLine].utf8.count

        while start > 0 || end < lines.count - 1 {
            // Try expanding upward
            if start > 0 {
                let lineSize = lines[start - 1].utf8.count + 1
                if currentSize + lineSize > budget { break }
                start -= 1
                currentSize += lineSize
            }

            // Try expanding downward
            if end < lines.count - 1 {
                let lineSize = lines[end + 1].utf8.count + 1
                if currentSize + lineSize > budget { break }
                end += 1
                currentSize += lineSize
            }

            // If we can't expand either direction, stop
            if start == 0, end == lines.count - 1 { break }
        }

        var result = lines[start...end].joined(separator: "\n")

        // Add truncation markers
        if start > 0 {
            result = "// ... (\(start) lines above) ...\n" + result
        }
        if end < lines.count - 1 {
            result = result + "\n// ... (\(lines.count - 1 - end) lines below) ..."
        }

        Self.logger.debug("Truncated context: lines \(start)-\(end) of \(lines.count)")
        return result
    }

    // MARK: - Injection Prevention

    /// Escape potential prompt injection markers in user-provided content.
    // L2 fix: also escape Unicode lookalikes used as replacements
    func escapeInjectionMarkers(_ text: String) -> String {
        text
            .replacingOccurrences(of: "--- FILE:", with: "- - - FILE:")
            .replacingOccurrences(of: "--- END FILE", with: "- - - END FILE")
            .replacingOccurrences(of: "─── FILE:", with: "- - - FILE:")
            .replacingOccurrences(of: "─── END FILE", with: "- - - END FILE")
            .replacingOccurrences(of: "<<<EDIT", with: "< < <EDIT")
            .replacingOccurrences(of: "EDIT>>>", with: "EDIT> > >")
            .replacingOccurrences(of: "«EDIT", with: "< < <EDIT")
            .replacingOccurrences(of: "EDIT»", with: "EDIT> > >")
    }
}
