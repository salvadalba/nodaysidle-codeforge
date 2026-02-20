import Foundation
import SwiftData

// MARK: - Schema V1

enum SchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [
            UserPreferences.self,
            RecentFile.self,
            AIConversation.self,
            KeyBinding.self
        ]
    }

    // MARK: UserPreferences — singleton, CloudKit-synced when opt-in

    @Model
    final class UserPreferences {
        var id: UUID = UUID()
        var theme: String = "dark"
        var fontName: String = "SF Mono"
        var fontSize: Double = 13.0
        var cloudKitSyncEnabled: Bool = false
        var scrollbackLines: Int = 10_000
        var createdAt: Date = Date()
        var updatedAt: Date = Date()

        init(
            theme: String = "dark",
            fontName: String = "SF Mono",
            fontSize: Double = 13.0,
            cloudKitSyncEnabled: Bool = false,
            scrollbackLines: Int = 10_000
        ) {
            self.id = UUID()
            self.theme = theme
            self.fontName = fontName
            self.fontSize = fontSize
            self.cloudKitSyncEnabled = cloudKitSyncEnabled
            self.scrollbackLines = scrollbackLines
            self.createdAt = Date()
            self.updatedAt = Date()
        }
    }

    // MARK: RecentFile — local-only, 20-entry LRU

    @Model
    final class RecentFile {
        var id: UUID = UUID()
        var filePath: String = ""
        var lastOpened: Date = Date()
        var cursorPosition: Int = 0
        var language: String = ""

        init(filePath: String, language: String, cursorPosition: Int = 0) {
            self.id = UUID()
            self.filePath = filePath
            self.lastOpened = Date()
            self.cursorPosition = cursorPosition
            self.language = language
        }
    }

    // MARK: AIConversation — local-only, encrypted messages blob

    @Model
    final class AIConversation {
        var id: UUID = UUID()
        var filePath: String = ""
        var createdAt: Date = Date()
        var encryptedMessages: Data = Data()

        init(filePath: String, encryptedMessages: Data = Data()) {
            self.id = UUID()
            self.filePath = filePath
            self.createdAt = Date()
            self.encryptedMessages = encryptedMessages
        }
    }

    // MARK: KeyBinding — CloudKit-synced when opt-in

    @Model
    final class KeyBinding {
        var id: UUID = UUID()
        var action: String = ""
        var keyCombination: String = ""
        var scope: String = "global"

        init(action: String, keyCombination: String, scope: String = "global") {
            self.id = UUID()
            self.action = action
            self.keyCombination = keyCombination
            self.scope = scope
        }
    }
}

// MARK: - Top-level type aliases

typealias UserPreferences = SchemaV1.UserPreferences
typealias RecentFile = SchemaV1.RecentFile
typealias AIConversation = SchemaV1.AIConversation
typealias KeyBinding = SchemaV1.KeyBinding

// MARK: - Migration Plan (baseline — no migrations yet)

enum CodeForgeMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [SchemaV1.self] }
    static var stages: [MigrationStage] { [] }
}
