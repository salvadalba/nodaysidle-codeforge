import SwiftUI

/// Chat-style sidebar for AI agent interaction.
///
/// Shows conversation history with user/assistant bubbles,
/// streams model output with animation, and provides
/// explain/suggest buttons using the current editor selection.
struct AIAgentView: View {
    @Bindable var model: AIAgentModel
    @Bindable var editorModel: EditorModel
    let inferenceActor: InferenceActor
    let persistenceService: PersistenceService?

    @State private var inputText: String = ""
    @State private var generationTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("AI Agent")
                    .font(.headline)
                Spacer()
                modelStateIndicator
                if model.isGenerating {
                    Button("Stop") { cancelGeneration() }
                        .buttonStyle(.plain)
                        .foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            // Messages
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(model.messages.enumerated()), id: \.offset) { index, message in
                            MessageBubble(message: message)
                                .id(index)
                        }
                        if !model.currentStreamingText.isEmpty {
                            StreamingBubble(text: model.currentStreamingText)
                                .id("streaming")
                        }
                    }
                    .padding(12)
                }
                .onChange(of: model.messages.count) {
                    withAnimation {
                        proxy.scrollTo(model.messages.count - 1, anchor: .bottom)
                    }
                }
                .onChange(of: model.currentStreamingText) {
                    withAnimation {
                        proxy.scrollTo("streaming", anchor: .bottom)
                    }
                }
            }

            Divider()

            // Action buttons
            HStack(spacing: 8) {
                Button("Explain") { explainSelection() }
                    .disabled(editorModel.selection.length == 0 || model.isGenerating)
                    .accessibilityLabel("Explain selected code")
                Button("Suggest Edit") { suggestEdit() }
                    .disabled(model.isGenerating)
                    .accessibilityLabel("Suggest code edits")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            // Input field
            HStack {
                TextField("Ask about your code...", text: $inputText)
                    .textFieldStyle(.plain)
                    .onSubmit { sendMessage() }
                    .disabled(model.isGenerating)

                Button(action: sendMessage) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .disabled(inputText.isEmpty || model.isGenerating)
                .buttonStyle(.plain)
            }
            .padding(12)
        }
        .frame(minWidth: 250)
        .background(.regularMaterial)
    }

    // MARK: - Model State

    @ViewBuilder
    private var modelStateIndicator: some View {
        switch model.modelState {
        case .notLoaded:
            Circle().fill(.gray).frame(width: 8, height: 8)
        case .downloading(let progress):
            ProgressView(value: progress)
                .frame(width: 40)
        case .loading:
            ProgressView()
                .controlSize(.small)
        case .loaded:
            Circle().fill(.green).frame(width: 8, height: 8)
        case .error:
            Circle().fill(.red).frame(width: 8, height: 8)
        }
    }

    // MARK: - Actions

    private func sendMessage() {
        let question = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        inputText = ""

        model.addUserMessage(question)
        model.isGenerating = true

        let context = editorModel.content
        let fileName = editorModel.fileURL?.lastPathComponent
        let language = editorModel.language
        let cursor = editorModel.cursorPosition

        generationTask = Task {
            await ensureModelLoaded()
            let stream = await inferenceActor.answer(
                question: question,
                fileContext: context,
                fileName: fileName,
                language: language,
                cursorPosition: cursor
            )
            for await text in stream {
                model.currentStreamingText = text
            }
            model.finalizeAssistantMessage()
            persistConversation()
        }
    }

    private func explainSelection() {
        let selection = extractSelection()
        guard !selection.isEmpty else { return }

        model.addUserMessage("Explain: \(selection.prefix(100))...")
        model.isGenerating = true

        let context = editorModel.content
        let fileName = editorModel.fileURL?.lastPathComponent
        let language = editorModel.language
        let cursor = editorModel.cursorPosition

        generationTask = Task {
            await ensureModelLoaded()
            let stream = await inferenceActor.explain(
                selection: selection,
                fileContext: context,
                fileName: fileName,
                language: language,
                cursorPosition: cursor
            )
            for await text in stream {
                model.currentStreamingText = text
            }
            model.finalizeAssistantMessage()
            persistConversation()
        }
    }

    private func suggestEdit() {
        let instruction = inputText.isEmpty ? "Improve this code" : inputText
        inputText = ""

        model.addUserMessage("Edit: \(instruction)")
        model.isGenerating = true

        let context = editorModel.content
        let fileName = editorModel.fileURL?.lastPathComponent
        let language = editorModel.language
        let cursor = editorModel.cursorPosition

        generationTask = Task {
            await ensureModelLoaded()
            var fullOutput = ""
            let stream = await inferenceActor.suggestEdit(
                instruction: instruction,
                fileContext: context,
                fileName: fileName,
                language: language,
                cursorPosition: cursor
            )
            for await text in stream {
                fullOutput = text
                model.currentStreamingText = text
            }
            model.finalizeAssistantMessage()
            persistConversation()

            // Parse edit suggestions from output
            let suggestions = EditSuggestion.parse(from: fullOutput)
            if !suggestions.isEmpty {
                model.pendingSuggestions = suggestions
            }
        }
    }

    private func cancelGeneration() {
        generationTask?.cancel()
        generationTask = nil
        model.finalizeAssistantMessage()
    }

    private func ensureModelLoaded() async {
        guard model.modelState != .loaded else { return }
        model.modelState = .loading
        do {
            try await inferenceActor.loadModel { progress in
                Task { @MainActor in
                    model.modelState = .downloading(
                        progress: progress.fractionCompleted
                    )
                }
            }
            model.modelState = .loaded
        } catch {
            model.modelState = .error(error.localizedDescription)
        }
    }

    private func persistConversation() {
        guard let service = persistenceService else { return }
        let filePath = editorModel.fileURL?.path(percentEncoded: false) ?? "untitled"
        try? service.saveConversation(messages: model.messages, filePath: filePath)
    }

    private func extractSelection() -> String {
        let range = editorModel.selection
        guard range.length > 0 else { return "" }
        let content = editorModel.content
        let utf16 = content.utf16
        guard let start = utf16.index(utf16.startIndex, offsetBy: range.location, limitedBy: utf16.endIndex),
              let end = utf16.index(start, offsetBy: range.length, limitedBy: utf16.endIndex) else {
            return ""
        }
        return String(content[start..<end])
    }
}

// MARK: - Message Views

private struct MessageBubble: View {
    let message: AIMessage

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 40) }

            Text(message.content)
                .padding(10)
                .background(message.role == .user ? Color.blue.opacity(0.2) : Color.gray.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .font(.system(.body, design: .monospaced))
                .accessibilityLabel("\(message.role == .user ? "You" : "Assistant"): \(message.content)")

            if message.role == .assistant { Spacer(minLength: 40) }
        }
    }
}

private struct StreamingBubble: View {
    let text: String

    var body: some View {
        HStack {
            Text(text)
                .padding(10)
                .background(Color.gray.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .font(.system(.body, design: .monospaced))
            Spacer(minLength: 40)
        }
        .opacity(0.8)
    }
}
