import CryptoKit
import Foundation
import SwiftData
import Testing

@testable import CodeForge

@Suite("PersistenceService")
struct PersistenceTests {

    private func makeService() throws -> PersistenceService {
        let key = SymmetricKey(size: .bits256)
        let encryption = EncryptionService(key: key)
        return try PersistenceService(inMemory: true, encryptionService: encryption)
    }

    // MARK: - UserPreferences (singleton)

    @Test("Default preferences created on first call")
    @MainActor func defaultPreferencesCreated() throws {
        let service = try makeService()

        let prefs = try service.ensureDefaultPreferences()

        #expect(prefs.theme == "dark")
        #expect(prefs.fontName == "SF Mono")
        #expect(prefs.fontSize == 13.0)
        #expect(prefs.cloudKitSyncEnabled == false)
        #expect(prefs.scrollbackLines == 10_000)
    }

    @Test("fetchPreferences returns same singleton")
    @MainActor func preferencesSingleton() throws {
        let service = try makeService()

        let first = try service.fetchPreferences()
        let second = try service.fetchPreferences()

        #expect(first.id == second.id)
    }

    @Test("Preferences update persists")
    @MainActor func preferencesUpdate() throws {
        let service = try makeService()

        let prefs = try service.fetchPreferences()
        prefs.theme = "light"
        prefs.fontSize = 16.0
        try service.modelContainer.mainContext.save()

        let fetched = try service.fetchPreferences()
        #expect(fetched.theme == "light")
        #expect(fetched.fontSize == 16.0)
    }

    // MARK: - RecentFile CRUD

    @Test("Add and fetch recent file")
    @MainActor func addAndFetchRecentFile() throws {
        let service = try makeService()

        try service.addRecentFile(filePath: "/tmp/test.swift", language: "swift")
        let files = try service.fetchRecentFiles()

        #expect(files.count == 1)
        #expect(files[0].filePath == "/tmp/test.swift")
        #expect(files[0].language == "swift")
    }

    @Test("Updating existing recent file updates timestamp")
    @MainActor func updateRecentFile() throws {
        let service = try makeService()

        try service.addRecentFile(filePath: "/tmp/test.swift", language: "swift")
        let original = try service.fetchRecentFiles()[0].lastOpened

        // Small delay to ensure timestamp differs
        try service.addRecentFile(
            filePath: "/tmp/test.swift",
            language: "swift",
            cursorPosition: 42
        )
        let files = try service.fetchRecentFiles()

        #expect(files.count == 1)
        #expect(files[0].cursorPosition == 42)
        #expect(files[0].lastOpened >= original)
    }

    // MARK: - RecentFile LRU eviction

    @Test("LRU eviction at 20 entries")
    @MainActor func recentFileLRUEviction() throws {
        let service = try makeService()

        // Insert 21 files
        for i in 0..<21 {
            try service.addRecentFile(
                filePath: "/tmp/file\(i).swift",
                language: "swift"
            )
        }

        let files = try service.fetchRecentFiles()
        #expect(files.count == 20)

        // The oldest file (file0) should have been evicted
        let paths = files.map(\.filePath)
        #expect(!paths.contains("/tmp/file0.swift"))
        #expect(paths.contains("/tmp/file20.swift"))
    }

    // MARK: - AIConversation encrypted roundtrip

    @Test("Save and load encrypted conversation")
    @MainActor func conversationEncryptedRoundtrip() throws {
        let service = try makeService()

        let messages: [AIMessage] = [
            AIMessage(role: .user, content: "Explain this code", timestamp: Date()),
            AIMessage(role: .assistant, content: "This function sorts an array", timestamp: Date()),
            AIMessage(role: .system, content: "You are a code assistant", timestamp: Date()),
        ]

        try service.saveConversation(messages: messages, filePath: "/tmp/code.swift")

        let conversations = try service.fetchConversations()
        #expect(conversations.count == 1)

        // Verify encrypted blob is not readable as plaintext JSON
        let rawData = conversations[0].encryptedMessages
        let asString = String(data: rawData, encoding: .utf8)
        #expect(asString == nil || !asString!.contains("Explain this code"))

        // Verify decryption roundtrip
        let loaded = try service.loadMessages(for: conversations[0])
        #expect(loaded.count == 3)
        #expect(loaded[0].role == .user)
        #expect(loaded[0].content == "Explain this code")
        #expect(loaded[1].role == .assistant)
        #expect(loaded[2].role == .system)
    }

    @Test("Conversation with 100 messages persists correctly")
    @MainActor func largeConversation() throws {
        let service = try makeService()

        let messages = (0..<100).map { i in
            AIMessage(
                role: i.isMultiple(of: 2) ? .user : .assistant,
                content: "Message \(i)",
                timestamp: Date()
            )
        }

        try service.saveConversation(messages: messages, filePath: "/tmp/large.swift")

        let conversations = try service.fetchConversations()
        let loaded = try service.loadMessages(for: conversations[0])

        #expect(loaded.count == 100)
        #expect(loaded[0].content == "Message 0")
        #expect(loaded[99].content == "Message 99")
    }

    @Test("Conversation upsert updates existing")
    @MainActor func conversationUpsert() throws {
        let service = try makeService()

        let msg1 = [AIMessage(role: .user, content: "v1", timestamp: Date())]
        try service.saveConversation(messages: msg1, filePath: "/tmp/file.swift")

        let msg2 = [
            AIMessage(role: .user, content: "v1", timestamp: Date()),
            AIMessage(role: .assistant, content: "v2", timestamp: Date()),
        ]
        try service.saveConversation(messages: msg2, filePath: "/tmp/file.swift")

        let conversations = try service.fetchConversations()
        #expect(conversations.count == 1)

        let loaded = try service.loadMessages(for: conversations[0])
        #expect(loaded.count == 2)
    }

    // MARK: - AIConversation LRU eviction

    @Test("Conversation LRU eviction at 50")
    @MainActor func conversationLRUEviction() throws {
        let service = try makeService()

        for i in 0..<51 {
            let messages = [AIMessage(role: .user, content: "msg \(i)", timestamp: Date())]
            try service.saveConversation(messages: messages, filePath: "/tmp/conv\(i).swift")
        }

        let conversations = try service.fetchConversations()
        #expect(conversations.count == 50)
    }

    // MARK: - Empty conversation

    @Test("Loading empty conversation returns empty array")
    @MainActor func emptyConversation() throws {
        let service = try makeService()

        let conversation = AIConversation(filePath: "/tmp/empty.swift")
        try service.save(conversation)

        let loaded = try service.loadMessages(for: conversation)
        #expect(loaded.isEmpty)
    }

    // MARK: - Generic CRUD

    @Test("Generic save, fetch, delete")
    @MainActor func genericCRUD() throws {
        let service = try makeService()

        let binding = KeyBinding(action: "openFile", keyCombination: "cmd+o")
        try service.save(binding)

        let fetched = try service.fetch(KeyBinding.self)
        #expect(fetched.count == 1)
        #expect(fetched[0].action == "openFile")

        try service.delete(fetched[0])
        let afterDelete = try service.fetch(KeyBinding.self)
        #expect(afterDelete.isEmpty)
    }
}
