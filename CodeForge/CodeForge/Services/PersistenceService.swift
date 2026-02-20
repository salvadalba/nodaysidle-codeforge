import Foundation
import OSLog
import SwiftData

enum PersistenceError: Error, LocalizedError, Sendable {
    case saveFailed(String)
    case fetchFailed(String)
    case deleteFailed(String)
    case encryptionFailed(String)
    case containerCreationFailed(String)

    var errorDescription: String? {
        switch self {
        case .saveFailed(let detail):
            "Failed to save: \(detail)"
        case .fetchFailed(let detail):
            "Failed to fetch: \(detail)"
        case .deleteFailed(let detail):
            "Failed to delete: \(detail)"
        case .encryptionFailed(let detail):
            "Encryption error: \(detail)"
        case .containerCreationFailed(let detail):
            "Failed to create data store: \(detail)"
        }
    }
}

/// Central persistence layer backed by SwiftData (SQLite).
///
/// Provides CRUD operations for all @Model types, LRU eviction for
/// RecentFile (20) and AIConversation (50), encrypted conversation
/// storage, and default UserPreferences creation on first launch.
@MainActor
final class PersistenceService {
    private static let logger = Logger(subsystem: "com.codeforge.app", category: "persistence")
    private static let recentFileLimit = 20
    private static let conversationLimit = 50

    let modelContainer: ModelContainer
    let encryptionService: EncryptionService

    /// Production singleton — call `bootstrap()` once at app launch.
    private(set) static var shared: PersistenceService?

    /// Initializes the shared instance. Safe to call multiple times (no-ops after first).
    static func bootstrap() async throws {
        guard shared == nil else { return }
        shared = try await PersistenceService()
    }

    /// Production initializer — SQLite at ~/Library/Application Support/CodeForge/.
    private init() async throws {
        let appSupportURL = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CodeForge", isDirectory: true)

        try FileManager.default.createDirectory(
            at: appSupportURL,
            withIntermediateDirectories: true
        )

        let schema = Schema(SchemaV1.models)
        let configuration = ModelConfiguration(
            schema: schema,
            url: appSupportURL.appendingPathComponent("CodeForge.sqlite"),
            allowsSave: true
        )

        self.modelContainer = try ModelContainer(
            for: schema,
            migrationPlan: CodeForgeMigrationPlan.self,
            configurations: [configuration]
        )

        self.encryptionService = try await EncryptionService()
        Self.logger.info("PersistenceService initialized at \(appSupportURL.path)")
    }

    /// Testing initializer — in-memory store, caller-provided encryption key.
    init(inMemory: Bool, encryptionService: EncryptionService) throws {
        let schema = Schema(SchemaV1.models)
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true
        )
        self.modelContainer = try ModelContainer(
            for: schema,
            configurations: [configuration]
        )
        self.encryptionService = encryptionService
    }

    // MARK: - UserPreferences (singleton)

    @discardableResult
    func ensureDefaultPreferences() throws -> UserPreferences {
        let context = modelContainer.mainContext
        var descriptor = FetchDescriptor<UserPreferences>()
        descriptor.fetchLimit = 1
        if let existing = try context.fetch(descriptor).first {
            return existing
        }
        let defaults = UserPreferences()
        context.insert(defaults)
        try context.save()
        Self.logger.info("Created default UserPreferences")
        return defaults
    }

    func fetchPreferences() throws -> UserPreferences {
        let context = modelContainer.mainContext
        var descriptor = FetchDescriptor<UserPreferences>()
        descriptor.fetchLimit = 1
        if let existing = try context.fetch(descriptor).first {
            return existing
        }
        return try ensureDefaultPreferences()
    }

    // MARK: - RecentFile (20-entry LRU)

    func addRecentFile(filePath: String, language: String, cursorPosition: Int = 0) throws {
        let context = modelContainer.mainContext

        // Update existing entry if present
        let predicate = #Predicate<RecentFile> { $0.filePath == filePath }
        let descriptor = FetchDescriptor<RecentFile>(predicate: predicate)
        if let existing = try context.fetch(descriptor).first {
            existing.lastOpened = Date()
            existing.cursorPosition = cursorPosition
            existing.language = language
            try context.save()
            try evictRecentFiles()
            return
        }

        let recentFile = RecentFile(
            filePath: filePath,
            language: language,
            cursorPosition: cursorPosition
        )
        context.insert(recentFile)
        try context.save()
        try evictRecentFiles()
    }

    func fetchRecentFiles() throws -> [RecentFile] {
        let context = modelContainer.mainContext
        var descriptor = FetchDescriptor<RecentFile>(
            sortBy: [SortDescriptor(\.lastOpened, order: .reverse)]
        )
        descriptor.fetchLimit = Self.recentFileLimit
        return try context.fetch(descriptor)
    }

    private func evictRecentFiles() throws {
        let context = modelContainer.mainContext
        let descriptor = FetchDescriptor<RecentFile>(
            sortBy: [SortDescriptor(\.lastOpened, order: .reverse)]
        )
        let allFiles = try context.fetch(descriptor)
        guard allFiles.count > Self.recentFileLimit else { return }

        for file in allFiles.dropFirst(Self.recentFileLimit) {
            context.delete(file)
        }
        try context.save()
        Self.logger.debug("Evicted \(allFiles.count - Self.recentFileLimit) recent file(s)")
    }

    // MARK: - AIConversation (50-entry LRU, encrypted)

    func saveConversation(messages: [AIMessage], filePath: String) throws {
        let context = modelContainer.mainContext

        let jsonData = try JSONEncoder().encode(messages)
        let encrypted = try encryptionService.encrypt(data: jsonData)

        // Upsert: update existing or create new
        let predicate = #Predicate<AIConversation> { $0.filePath == filePath }
        let descriptor = FetchDescriptor<AIConversation>(predicate: predicate)
        if let existing = try context.fetch(descriptor).first {
            existing.encryptedMessages = encrypted
            try context.save()
            return
        }

        let conversation = AIConversation(
            filePath: filePath,
            encryptedMessages: encrypted
        )
        context.insert(conversation)
        try context.save()
        try evictConversations()
    }

    func loadMessages(for conversation: AIConversation) throws -> [AIMessage] {
        guard !conversation.encryptedMessages.isEmpty else { return [] }
        let decrypted = try encryptionService.decrypt(data: conversation.encryptedMessages)
        return try JSONDecoder().decode([AIMessage].self, from: decrypted)
    }

    func fetchConversations() throws -> [AIConversation] {
        let context = modelContainer.mainContext
        let descriptor = FetchDescriptor<AIConversation>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return try context.fetch(descriptor)
    }

    private func evictConversations() throws {
        let context = modelContainer.mainContext
        let descriptor = FetchDescriptor<AIConversation>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        let all = try context.fetch(descriptor)
        guard all.count > Self.conversationLimit else { return }

        for conversation in all.dropFirst(Self.conversationLimit) {
            context.delete(conversation)
        }
        try context.save()
        Self.logger.debug("Evicted \(all.count - Self.conversationLimit) conversation(s)")
    }

    // MARK: - KeyBinding

    func fetchKeyBindings() throws -> [KeyBinding] {
        let context = modelContainer.mainContext
        return try context.fetch(FetchDescriptor<KeyBinding>())
    }

    // MARK: - Generic CRUD

    func save<T: PersistentModel>(_ model: T) throws {
        let context = modelContainer.mainContext
        context.insert(model)
        try context.save()
    }

    func fetch<T: PersistentModel>(
        _ type: T.Type,
        predicate: Predicate<T>? = nil,
        sortBy: [SortDescriptor<T>] = []
    ) throws -> [T] {
        let context = modelContainer.mainContext
        let descriptor = FetchDescriptor<T>(predicate: predicate, sortBy: sortBy)
        return try context.fetch(descriptor)
    }

    func delete<T: PersistentModel>(_ model: T) throws {
        let context = modelContainer.mainContext
        context.delete(model)
        try context.save()
    }
}
