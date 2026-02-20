import Foundation
import SwiftUI
import Testing

@testable import CodeForge

// MARK: - KeyBindingService

@Suite("KeyBindingService")
struct KeyBindingServiceTests {

    @Test("Parse simple key combo: cmd+o")
    func parseCmdO() {
        let result = KeyBindingService.parse(keyCombination: "cmd+o")

        #expect(result != nil)
        #expect(result?.modifiers == .command)
    }

    @Test("Parse combo with shift: cmd+shift+a")
    func parseCmdShiftA() {
        let result = KeyBindingService.parse(keyCombination: "cmd+shift+a")

        #expect(result != nil)
        #expect(result?.modifiers == [.command, .shift])
    }

    @Test("Parse combo with control: ctrl+c")
    func parseCtrlC() {
        let result = KeyBindingService.parse(keyCombination: "ctrl+c")

        #expect(result != nil)
        #expect(result?.modifiers == .control)
    }

    @Test("Parse combo with option: opt+shift+f")
    func parseOptShiftF() {
        let result = KeyBindingService.parse(keyCombination: "opt+shift+f")

        #expect(result != nil)
        #expect(result?.modifiers == [.option, .shift])
    }

    @Test("Parse case insensitive: CMD+S")
    func parseCaseInsensitive() {
        let result = KeyBindingService.parse(keyCombination: "CMD+S")

        #expect(result != nil)
        #expect(result?.modifiers == .command)
    }

    @Test("Parse returns nil for empty string")
    func parseEmpty() {
        let result = KeyBindingService.parse(keyCombination: "")
        #expect(result == nil)
    }

    @Test("Parse returns nil for multi-char key")
    func parseMultiCharKey() {
        let result = KeyBindingService.parse(keyCombination: "cmd+enter")
        #expect(result == nil)
    }

    @Test("Default bindings has expected count")
    func defaultBindingsCount() {
        #expect(KeyBindingService.defaults.count == 9)
    }

    @Test("Conflict detection finds matching combo")
    func conflictDetection() {
        let service = KeyBindingService()
        service.bindings = KeyBindingService.defaults.map { def in
            KeyBinding(action: def.action, keyCombination: def.keyCombination)
        }

        let conflict = service.hasConflict(
            keyCombination: "cmd+o",
            excludingAction: "someOtherAction"
        )
        #expect(conflict == "openFile")
    }

    @Test("Conflict detection excludes same action")
    func noSelfConflict() {
        let service = KeyBindingService()
        service.bindings = KeyBindingService.defaults.map { def in
            KeyBinding(action: def.action, keyCombination: def.keyCombination)
        }

        let conflict = service.hasConflict(
            keyCombination: "cmd+o",
            excludingAction: "openFile"
        )
        #expect(conflict == nil)
    }

    @Test("Display names for all default actions")
    func displayNames() {
        for def in KeyBindingService.defaults {
            let name = KeyBindingService.displayName(for: def.action)
            #expect(!name.isEmpty)
            #expect(name != def.action) // Should have a human-readable name
        }
    }
}

// MARK: - Notification Names

@Suite("App Notification Names")
struct NotificationNameTests {

    @Test("Notification names are distinct")
    func distinctNames() {
        let names: [Notification.Name] = [
            .toggleAIPanel,
            .toggleTerminal,
            .explainSelection,
            .suggestEdit,
            .askQuestion,
        ]
        let unique = Set(names)
        #expect(unique.count == names.count)
    }
}

// MARK: - ModelDownloader

@Suite("ModelDownloader")
struct ModelDownloaderTests {

    @Test("Default model ID is set")
    func defaultModelID() {
        #expect(!ModelDownloader.defaultModelID.isEmpty)
        #expect(ModelDownloader.defaultModelID.contains("/"))
    }

    @Test("Models directory is in Application Support")
    func modelsDirectory() {
        let dir = ModelDownloader.modelsDirectory
        #expect(dir.path.contains("Application Support"))
        #expect(dir.path.contains("CodeForge"))
    }

    @Test("Local model directory replaces slashes")
    func localModelDirectory() {
        let downloader = ModelDownloader()
        let dir = downloader.localModelDirectory()
        #expect(!dir.lastPathComponent.contains("/"))
        #expect(dir.lastPathComponent.contains("--"))
    }
}
