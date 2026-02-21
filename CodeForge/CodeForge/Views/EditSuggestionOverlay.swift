import SwiftUI

/// Overlay that shows pending AI edit suggestions as inline diffs.
///
/// Displays original code with strikethrough and replacement in green,
/// with Accept/Reject buttons per suggestion.
struct EditSuggestionOverlay: View {
    @Bindable var agentModel: AIAgentModel
    @Bindable var editorModel: EditorModel

    var body: some View {
        if !agentModel.pendingSuggestions.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("\(agentModel.pendingSuggestions.count) suggestion(s)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Accept All") { acceptAll() }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.green)
                    Button("Reject All") { rejectAll() }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)

                Divider()

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(agentModel.pendingSuggestions) { suggestion in
                            SuggestionCard(
                                suggestion: suggestion,
                                onAccept: { accept(suggestion) },
                                onReject: { reject(suggestion) }
                            )
                        }
                    }
                    .padding(12)
                }
            }
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
        }
    }

    // MARK: - Actions

    private func accept(_ suggestion: EditSuggestion) {
        guard applySuggestion(suggestion) else { return }
        agentModel.pendingSuggestions.removeAll { $0.id == suggestion.id }
    }

    private func reject(_ suggestion: EditSuggestion) {
        agentModel.pendingSuggestions.removeAll { $0.id == suggestion.id }
    }

    private func acceptAll() {
        // Apply in reverse order so byte offsets remain valid
        let sorted = agentModel.pendingSuggestions.sorted { $0.startByte > $1.startByte }
        for suggestion in sorted {
            _ = applySuggestion(suggestion)
        }
        agentModel.pendingSuggestions.removeAll()
    }

    private func rejectAll() {
        agentModel.pendingSuggestions.removeAll()
    }

    /// C4 fix: validate that the original text at the byte range still matches
    /// the suggestion's expected original text before applying.
    /// Returns false if the suggestion is stale.
    @discardableResult
    private func applySuggestion(_ suggestion: EditSuggestion) -> Bool {
        let content = editorModel.content
        let utf8 = content.utf8
        let utf8Count = utf8.count

        // Validate byte offsets
        guard suggestion.startByte >= 0,
              suggestion.endByte > suggestion.startByte,
              suggestion.endByte <= utf8Count else {
            return false
        }

        let startIndex = utf8.index(utf8.startIndex, offsetBy: suggestion.startByte)
        let endIndex = utf8.index(utf8.startIndex, offsetBy: suggestion.endByte)

        guard let startStr = String.Index(startIndex, within: content),
              let endStr = String.Index(endIndex, within: content) else {
            return false
        }

        // Verify the text at this range still matches the expected original
        let currentText = String(content[startStr..<endStr])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let expectedText = suggestion.original
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard currentText == expectedText else {
            return false
        }

        editorModel.content.replaceSubrange(startStr..<endStr, with: suggestion.replacement)
        editorModel.isDirty = true
        return true
    }
}

// MARK: - Suggestion Card

private struct SuggestionCard: View {
    let suggestion: EditSuggestion
    let onAccept: () -> Void
    let onReject: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Explanation
            Text(suggestion.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)

            // Diff view
            VStack(alignment: .leading, spacing: 2) {
                // Original (strikethrough red)
                Text(suggestion.original)
                    .font(.system(.caption, design: .monospaced))
                    .strikethrough(true, color: .red)
                    .foregroundStyle(.red.opacity(0.7))
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.08))

                // Replacement (green)
                Text(suggestion.replacement)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.green)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.green.opacity(0.08))
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))

            // Actions
            HStack(spacing: 8) {
                Spacer()
                Button("Reject", action: onReject)
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.red)
                Button("Accept", action: onAccept)
                    .buttonStyle(.bordered)
                    .font(.caption)
                    .tint(.green)
            }
        }
        .padding(10)
        .background(Color.gray.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
