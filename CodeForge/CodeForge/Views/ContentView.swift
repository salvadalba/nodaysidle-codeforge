import SwiftUI

/// Root three-panel layout: editor (center), AI sidebar (right), terminal (bottom).
///
/// Uses VSplitView for vertical split (editor area + terminal) and
/// HSplitView for horizontal split (editor + AI sidebar).
/// Panels are collapsible via model visibility flags.
struct ContentView: View {
    @State private var editorModel = EditorModel()
    @State private var agentModel = AIAgentModel()
    @State private var terminalModel = TerminalModel()
    @State private var errorMessage: String?

    private let parsingActor = ParsingActor()
    private let inferenceActor = InferenceActor()
    private let terminalActor = TerminalActor()
    private let editorService = EditorService()

    var body: some View {
        VSplitView {
            // Top: Editor + AI sidebar
            HSplitView {
                // Editor (center)
                EditorView(model: editorModel, parsingActor: parsingActor)
                    .frame(minWidth: 400, minHeight: 200)
                    .accessibilityLabel("Code Editor")
                    .accessibilityHint("Edit your source code here")

                // AI sidebar (right, collapsible)
                if agentModel.isPanelVisible {
                    AIAgentView(
                        model: agentModel,
                        editorModel: editorModel,
                        inferenceActor: inferenceActor,
                        persistenceService: PersistenceService.shared
                    )
                    .frame(minWidth: 250, idealWidth: 320, maxWidth: 500)
                    .accessibilityLabel("AI Assistant Panel")
                    .overlay(alignment: .bottom) {
                        EditSuggestionOverlay(
                            agentModel: agentModel,
                            editorModel: editorModel
                        )
                        .frame(maxHeight: 300)
                        .padding(8)
                    }
                }
            }
            .frame(minHeight: 200)

            // Terminal (bottom, collapsible)
            if terminalModel.isVisible {
                TerminalView(model: terminalModel, terminalActor: terminalActor)
                    .frame(minHeight: 100, idealHeight: 200, maxHeight: 400)
                    .accessibilityLabel("Terminal")
                    .accessibilityHint("Interactive shell terminal")
            }
        }
        .task {
            // Stream highlight ranges from parser to editor
            for await ranges in parsingActor.highlightStream {
                editorModel.highlightRanges = ranges
                editorModel.isParsing = false
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Open") { openFile() }
                    .keyboardShortcut("o", modifiers: .command)

                Button("Save") { saveFile() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!editorModel.isDirty)
            }

            ToolbarItemGroup(placement: .automatic) {
                Button {
                    withAnimation { agentModel.isPanelVisible.toggle() }
                } label: {
                    Image(systemName: agentModel.isPanelVisible ? "sidebar.trailing" : "sidebar.right")
                }
                .help(agentModel.isPanelVisible ? "Hide AI Panel" : "Show AI Panel")
                .accessibilityLabel(agentModel.isPanelVisible ? "Hide AI Panel" : "Show AI Panel")

                Button {
                    withAnimation { terminalModel.isVisible.toggle() }
                } label: {
                    Image(systemName: "terminal")
                }
                .help(terminalModel.isVisible ? "Hide Terminal" : "Show Terminal")
                .accessibilityLabel(terminalModel.isVisible ? "Hide Terminal" : "Show Terminal")
            }
        }
        .alert("Error", isPresented: .init(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .onDisappear {
            // Schedule model unload when window closes
            Task { await inferenceActor.scheduleUnload() }
        }
    }

    // MARK: - File Actions

    // M1 fix: confirm before discarding unsaved changes
    private func openFile() {
        if editorModel.isDirty {
            let alert = NSAlert()
            alert.messageText = "Unsaved Changes"
            alert.informativeText = "You have unsaved changes. Do you want to save before opening a new file?"
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Don't Save")
            alert.addButton(withTitle: "Cancel")
            let response = alert.runModal()
            switch response {
            case .alertFirstButtonReturn:
                saveFile()
            case .alertThirdButtonReturn:
                return
            default:
                break
            }
        }

        guard let url = editorService.showOpenPanel() else { return }
        do {
            let (content, language) = try editorService.open(url: url)
            editorModel.content = content
            editorModel.language = language
            editorModel.fileURL = url
            editorModel.isDirty = false
            editorModel.highlightRanges = []

            Task {
                try? await parsingActor.setLanguage(language)
                editorModel.isParsing = true
                await parsingActor.fullParse(source: content)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func saveFile() {
        guard editorModel.isDirty else { return }
        do {
            if let url = editorModel.fileURL {
                try editorService.save(content: editorModel.content, to: url)
                editorModel.isDirty = false
                editorService.clearAutosave(for: url)
            } else {
                if let url = try editorService.showSavePanel(
                    content: editorModel.content,
                    suggestedName: nil
                ) {
                    editorModel.fileURL = url
                    editorModel.isDirty = false
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
