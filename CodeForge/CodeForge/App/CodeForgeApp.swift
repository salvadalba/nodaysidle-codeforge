import OSLog
import SwiftData
import SwiftUI

// MARK: - OSLog categories

extension Logger {
    private static let subsystem = "com.codeforge.app"

    static let editor = Logger(subsystem: subsystem, category: "editor")
    static let parsing = Logger(subsystem: subsystem, category: "parsing")
    static let inference = Logger(subsystem: subsystem, category: "inference")
    static let terminal = Logger(subsystem: subsystem, category: "terminal")
}

// MARK: - App entry point

@main
struct CodeForgeApp: App {
    @State private var isReady = false
    @State private var bootstrapError: String?

    var body: some Scene {
        WindowGroup {
            if let error = bootstrapError {
                // C3 fix: show error UI instead of fatalError on persistence failure
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 48))
                        .foregroundStyle(.orange)
                    Text("CodeForge failed to start")
                        .font(.title2)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    Button("Quit") { NSApplication.shared.terminate(nil) }
                        .keyboardShortcut("q")
                }
                .frame(minWidth: 400, minHeight: 200)
            } else if isReady, let service = PersistenceService.shared {
                ContentView()
                    .modelContainer(service.modelContainer)
                    .frame(minWidth: 800, minHeight: 500)
            } else {
                ProgressView("Starting CodeForge\u{2026}")
                    .task {
                        do {
                            try await PersistenceService.bootstrap()
                            isReady = true
                        } catch {
                            bootstrapError = error.localizedDescription
                        }
                    }
            }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .defaultSize(width: 1200, height: 800)
        .commands {
            // File menu additions
            CommandGroup(after: .newItem) {
                Divider()
                Button("Open\u{2026}") {
                    // Handled by ContentView toolbar
                }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(true) // Wired via ContentView

                Button("Save") {}
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(true) // Wired via ContentView
            }

            // View menu
            CommandMenu("View") {
                Button("Toggle AI Panel") {
                    NotificationCenter.default.post(
                        name: .toggleAIPanel,
                        object: nil
                    )
                }
                .keyboardShortcut("a", modifiers: [.command, .shift])

                Button("Toggle Terminal") {
                    NotificationCenter.default.post(
                        name: .toggleTerminal,
                        object: nil
                    )
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])
            }

            // AI menu
            CommandMenu("AI") {
                Button("Explain Selection") {
                    NotificationCenter.default.post(
                        name: .explainSelection,
                        object: nil
                    )
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])

                Button("Suggest Edit") {
                    NotificationCenter.default.post(
                        name: .suggestEdit,
                        object: nil
                    )
                }

                Button("Ask Question") {
                    NotificationCenter.default.post(
                        name: .askQuestion,
                        object: nil
                    )
                }
                .keyboardShortcut("q", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let toggleAIPanel = Notification.Name("CodeForge.toggleAIPanel")
    static let toggleTerminal = Notification.Name("CodeForge.toggleTerminal")
    static let explainSelection = Notification.Name("CodeForge.explainSelection")
    static let suggestEdit = Notification.Name("CodeForge.suggestEdit")
    static let askQuestion = Notification.Name("CodeForge.askQuestion")
}
