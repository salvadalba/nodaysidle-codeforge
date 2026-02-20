import SwiftData
import SwiftUI

/// Settings scene with tabs for Appearance, Editor, AI, and Key Bindings.
struct SettingsView: View {
    var body: some View {
        TabView {
            AppearanceSettingsTab()
                .tabItem { Label("Appearance", systemImage: "paintbrush") }

            EditorSettingsTab()
                .tabItem { Label("Editor", systemImage: "doc.text") }

            AISettingsTab()
                .tabItem { Label("AI", systemImage: "cpu") }

            KeyBindingsSettingsTab()
                .tabItem { Label("Key Bindings", systemImage: "keyboard") }
        }
        .frame(width: 500, height: 400)
    }
}

// MARK: - Appearance

private struct AppearanceSettingsTab: View {
    @State private var theme: String = "dark"

    var body: some View {
        Form {
            Picker("Theme", selection: $theme) {
                Text("Dark").tag("dark")
                Text("Light").tag("light")
            }
            .pickerStyle(.segmented)
        }
        .formStyle(.grouped)
        .onAppear { loadPreferences() }
        .onChange(of: theme) { savePreferences() }
    }

    private func loadPreferences() {
        guard let service = PersistenceService.shared else { return }
        if let prefs = try? service.fetchPreferences() {
            theme = prefs.theme
        }
    }

    private func savePreferences() {
        guard let service = PersistenceService.shared else { return }
        if let prefs = try? service.fetchPreferences() {
            prefs.theme = theme
            prefs.updatedAt = Date()
            try? service.modelContainer.mainContext.save()
        }
    }
}

// MARK: - Editor

private struct EditorSettingsTab: View {
    @State private var fontName: String = "SF Mono"
    @State private var fontSize: Double = 13.0
    @State private var scrollbackLines: Int = 10_000

    var body: some View {
        Form {
            TextField("Font Name", text: $fontName)

            HStack {
                Text("Font Size")
                Slider(value: $fontSize, in: 9...36, step: 1)
                Text("\(Int(fontSize)) pt")
                    .monospacedDigit()
                    .frame(width: 50)
            }

            HStack {
                Text("Scrollback Lines")
                Slider(
                    value: .init(
                        get: { Double(scrollbackLines) },
                        set: { scrollbackLines = Int($0) }
                    ),
                    in: 1000...50000,
                    step: 1000
                )
                Text("\(scrollbackLines)")
                    .monospacedDigit()
                    .frame(width: 60)
            }
        }
        .formStyle(.grouped)
        .onAppear { loadPreferences() }
        .onChange(of: fontName) { savePreferences() }
        .onChange(of: fontSize) { savePreferences() }
        .onChange(of: scrollbackLines) { savePreferences() }
    }

    private func loadPreferences() {
        guard let service = PersistenceService.shared else { return }
        if let prefs = try? service.fetchPreferences() {
            fontName = prefs.fontName
            fontSize = prefs.fontSize
            scrollbackLines = prefs.scrollbackLines
        }
    }

    private func savePreferences() {
        guard let service = PersistenceService.shared else { return }
        if let prefs = try? service.fetchPreferences() {
            prefs.fontName = fontName
            prefs.fontSize = fontSize
            prefs.scrollbackLines = scrollbackLines
            prefs.updatedAt = Date()
            try? service.modelContainer.mainContext.save()
        }
    }
}

// MARK: - AI

private struct AISettingsTab: View {
    @State private var cloudKitSyncEnabled: Bool = false

    var body: some View {
        Form {
            Toggle("Sync preferences via iCloud", isOn: $cloudKitSyncEnabled)

            Section("Model") {
                LabeledContent("Default Model") {
                    Text(ModelDownloader.defaultModelID)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                LabeledContent("Model Directory") {
                    Text(ModelDownloader.modelsDirectory.path)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { loadPreferences() }
        .onChange(of: cloudKitSyncEnabled) { savePreferences() }
    }

    private func loadPreferences() {
        guard let service = PersistenceService.shared else { return }
        if let prefs = try? service.fetchPreferences() {
            cloudKitSyncEnabled = prefs.cloudKitSyncEnabled
        }
    }

    private func savePreferences() {
        guard let service = PersistenceService.shared else { return }
        if let prefs = try? service.fetchPreferences() {
            prefs.cloudKitSyncEnabled = cloudKitSyncEnabled
            prefs.updatedAt = Date()
            try? service.modelContainer.mainContext.save()
        }
    }
}

// MARK: - Key Bindings

private struct KeyBindingsSettingsTab: View {
    @State private var bindings: [(action: String, keyCombination: String)] =
        KeyBindingService.defaults
    @State private var conflictMessage: String?

    var body: some View {
        Form {
            ForEach(Array(bindings.enumerated()), id: \.offset) { index, binding in
                HStack {
                    Text(KeyBindingService.displayName(for: binding.action))
                        .frame(width: 150, alignment: .leading)

                    TextField(
                        "Key combo",
                        text: .init(
                            get: { binding.keyCombination },
                            set: { newValue in
                                bindings[index].keyCombination = newValue
                            }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 160)
                    .onChange(of: bindings[index].keyCombination) {
                        checkConflict(at: index)
                        saveBindings()
                    }
                }
            }

            if let conflict = conflictMessage {
                Text(conflict)
                    .foregroundStyle(.orange)
                    .font(.caption)
            }
        }
        .formStyle(.grouped)
        .onAppear { loadBindings() }
    }

    private func loadBindings() {
        guard let service = PersistenceService.shared else { return }
        if let stored = try? service.fetchKeyBindings(), !stored.isEmpty {
            bindings = stored.map { ($0.action, $0.keyCombination) }
        }
    }

    private func saveBindings() {
        guard let service = PersistenceService.shared else { return }
        let context = service.modelContainer.mainContext
        // Delete existing bindings and replace with current state
        if let existing = try? service.fetchKeyBindings() {
            for binding in existing {
                context.delete(binding)
            }
        }
        for binding in bindings {
            let kb = KeyBinding(action: binding.action, keyCombination: binding.keyCombination)
            context.insert(kb)
        }
        try? context.save()
    }

    private func checkConflict(at index: Int) {
        let combo = bindings[index].keyCombination
        let action = bindings[index].action
        let conflicting = bindings.first {
            $0.action != action &&
            $0.keyCombination.lowercased() == combo.lowercased()
        }
        if let conflicting {
            conflictMessage = "'\(combo)' conflicts with \(KeyBindingService.displayName(for: conflicting.action))"
        } else {
            conflictMessage = nil
        }
    }
}
