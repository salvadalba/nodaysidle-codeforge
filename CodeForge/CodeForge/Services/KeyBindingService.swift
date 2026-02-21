import AppKit
import Foundation
import OSLog
import SwiftData
import SwiftUI

/// Manages keyboard shortcuts loaded from SwiftData KeyBinding entries.
///
/// Parses human-readable key combo strings like "cmd+shift+p" into
/// SwiftUI EventModifiers + KeyEquivalent pairs, and maps actions
/// to their corresponding app commands.
@Observable
final class KeyBindingService {
    private static let logger = Logger(subsystem: "com.codeforge.app", category: "editor")

    /// All loaded key bindings.
    var bindings: [KeyBinding] = []

    /// Known actions and their default key combos.
    static let defaults: [(action: String, keyCombination: String)] = [
        ("openFile", "cmd+o"),
        ("saveFile", "cmd+s"),
        ("toggleAIPanel", "cmd+shift+a"),
        ("toggleTerminal", "cmd+shift+t"),
        ("undo", "cmd+z"),
        ("redo", "cmd+shift+z"),
        ("explain", "cmd+shift+e"),
        ("suggestEdit", "cmd+shift+s"),
        ("askQuestion", "cmd+shift+q"),
    ]

    /// Load bindings from persistence, falling back to defaults if none exist.
    // M10 fix: persist default bindings to SwiftData on first load
    func loadBindings(from persistenceService: PersistenceService) {
        do {
            let stored = try persistenceService.fetchKeyBindings()
            if stored.isEmpty {
                let defaults = Self.defaults.map { def in
                    KeyBinding(action: def.action, keyCombination: def.keyCombination)
                }
                let context = persistenceService.modelContainer.mainContext
                for binding in defaults {
                    context.insert(binding)
                }
                try? context.save()
                bindings = defaults
            } else {
                bindings = stored
            }
        } catch {
            Self.logger.error("Failed to load key bindings: \(error.localizedDescription)")
            bindings = Self.defaults.map { def in
                KeyBinding(action: def.action, keyCombination: def.keyCombination)
            }
        }
    }

    /// Parse a key combination string like "cmd+shift+p" into SwiftUI types.
    static func parse(keyCombination: String) -> (modifiers: EventModifiers, key: KeyEquivalent)? {
        let parts = keyCombination.lowercased().split(separator: "+").map(String.init)
        guard let keyPart = parts.last, keyPart.count == 1,
              let char = keyPart.first else {
            return nil
        }

        var modifiers: EventModifiers = []
        for part in parts.dropLast() {
            switch part.trimmingCharacters(in: .whitespaces) {
            case "cmd", "command": modifiers.insert(.command)
            case "shift": modifiers.insert(.shift)
            case "opt", "option", "alt": modifiers.insert(.option)
            case "ctrl", "control": modifiers.insert(.control)
            default: break
            }
        }

        return (modifiers, KeyEquivalent(char))
    }

    /// Check if a key combo string conflicts with an existing binding (excluding a given action).
    func hasConflict(keyCombination: String, excludingAction: String) -> String? {
        bindings.first {
            $0.action != excludingAction &&
            $0.keyCombination.lowercased() == keyCombination.lowercased()
        }?.action
    }

    /// Human-readable display name for an action.
    static func displayName(for action: String) -> String {
        switch action {
        case "openFile": "Open File"
        case "saveFile": "Save File"
        case "toggleAIPanel": "Toggle AI Panel"
        case "toggleTerminal": "Toggle Terminal"
        case "undo": "Undo"
        case "redo": "Redo"
        case "explain": "Explain Selection"
        case "suggestEdit": "Suggest Edit"
        case "askQuestion": "Ask Question"
        default: action
        }
    }
}
