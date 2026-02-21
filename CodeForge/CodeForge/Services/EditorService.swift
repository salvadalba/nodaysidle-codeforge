import AppKit
import Foundation
import OSLog
import UniformTypeIdentifiers

enum EditorError: Error, LocalizedError, Sendable {
    case fileNotFound(String)
    case notRegularFile(String)
    case notReadable(String)
    case unsupportedLanguage(String)
    case notUTF8(String)
    case tooManyLines(Int)
    case isSymlink(String)
    case saveFailed(String)
    case bookmarkFailed(String)

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let path):
            "File not found: \(path)"
        case .notRegularFile(let path):
            "Not a regular file: \(path)"
        case .notReadable(let path):
            "File is not readable: \(path)"
        case .unsupportedLanguage(let ext):
            "Unsupported file type: .\(ext). Only .swift and .py are supported."
        case .notUTF8(let path):
            "File is not valid UTF-8: \(path)"
        case .tooManyLines(let count):
            "File has \(count) lines, exceeding the 50,000 line limit."
        case .isSymlink(let path):
            "Symlinks are not supported: \(path)"
        case .saveFailed(let detail):
            "Failed to save: \(detail)"
        case .bookmarkFailed(let detail):
            "Bookmark error: \(detail)"
        }
    }
}

/// Handles file I/O for the editor: open with validation, atomic save,
/// security-scoped bookmarks, and debounced autosave to a temp file.
/// M8 fix: @MainActor isolation prevents data race on autosaveTask.
@MainActor
final class EditorService {
    private static let logger = Logger(subsystem: "com.codeforge.app", category: "editor")
    private static let maxLines = 50_000
    private static let autosaveDelay: Duration = .seconds(5)
    private static let allowedExtensions: Set<String> = ["swift", "py"]

    private let bookmarkDefaults = UserDefaults.standard
    private var autosaveTask: Task<Void, Never>?

    // MARK: - Open

    /// Open and validate a source file.
    /// - Validates: exists, regular file (no symlinks), readable, UTF-8, ≤50K lines, .swift/.py
    /// - Returns: Tuple of content string and detected language
    func open(url: URL) throws(EditorError) -> (content: String, language: SourceLanguage) {
        // H5 fix: start security-scoped resource access for sandboxed builds
        let didStartAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let path = url.path(percentEncoded: false)

        // Symlink check
        let attrs: [FileAttributeKey: Any]
        do {
            attrs = try FileManager.default.attributesOfItem(atPath: path)
        } catch {
            throw .fileNotFound(path)
        }
        if attrs[.type] as? FileAttributeType == .typeSymbolicLink {
            throw .isSymlink(path)
        }

        // Exists and is regular file
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            throw .notRegularFile(path)
        }

        guard FileManager.default.isReadableFile(atPath: path) else {
            throw .notReadable(path)
        }

        // Extension check
        let ext = url.pathExtension.lowercased()
        guard Self.allowedExtensions.contains(ext) else {
            throw .unsupportedLanguage(ext)
        }

        guard let language = SourceLanguage.from(extension: ext) else {
            throw .unsupportedLanguage(ext)
        }

        // Read and validate UTF-8
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw .notReadable(path)
        }

        guard let content = String(data: data, encoding: .utf8) else {
            throw .notUTF8(path)
        }

        // Line count check
        let lineCount = content.components(separatedBy: .newlines).count
        if lineCount > Self.maxLines {
            throw .tooManyLines(lineCount)
        }

        Self.logger.info("Opened \(url.lastPathComponent) (\(lineCount) lines, \(ext))")

        // Store security-scoped bookmark
        storeBookmark(for: url)

        return (content, language)
    }

    // MARK: - Open Panel

    /// Present an NSOpenPanel filtered to .swift and .py files.
    /// Returns the selected URL, or nil if cancelled.
    @MainActor
    func showOpenPanel() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.swiftSource, .pythonScript]
        panel.message = "Select a .swift or .py file to edit"

        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    // MARK: - Save

    /// Atomically save content to a file URL.
    func save(content: String, to url: URL) throws(EditorError) {
        let data = Data(content.utf8)
        do {
            try data.write(to: url, options: [.atomic])
            Self.logger.info("Saved \(url.lastPathComponent)")
        } catch {
            throw .saveFailed(error.localizedDescription)
        }
    }

    /// Present an NSSavePanel and save content.
    /// Returns the chosen URL, or nil if cancelled.
    @MainActor
    func showSavePanel(content: String, suggestedName: String?) throws(EditorError) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.swiftSource, .pythonScript]
        if let name = suggestedName {
            panel.nameFieldStringValue = name
        }

        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        try save(content: content, to: url)
        storeBookmark(for: url)
        return url
    }

    // MARK: - Autosave

    /// Start debounced autosave. Each call resets the 5-second timer.
    func scheduleAutosave(content: String, originalURL: URL?) {
        autosaveTask?.cancel()
        autosaveTask = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.autosaveDelay)
            } catch {
                return // cancelled
            }
            self?.performAutosave(content: content, originalURL: originalURL)
        }
    }

    /// Cancel any pending autosave.
    func cancelAutosave() {
        autosaveTask?.cancel()
        autosaveTask = nil
    }

    private func performAutosave(content: String, originalURL: URL?) {
        let tempDir = FileManager.default.temporaryDirectory
        let fileName: String
        if let original = originalURL {
            fileName = ".codeforge-autosave-\(original.lastPathComponent)"
        } else {
            fileName = ".codeforge-autosave-untitled"
        }
        let tempURL = tempDir.appendingPathComponent(fileName)

        do {
            try Data(content.utf8).write(to: tempURL, options: [.atomic])
            Self.logger.debug("Autosaved to \(tempURL.lastPathComponent)")
        } catch {
            Self.logger.error("Autosave failed: \(error.localizedDescription)")
        }
    }

    /// Check for and recover autosave data for a given file URL.
    func recoverAutosave(for url: URL) -> String? {
        let tempDir = FileManager.default.temporaryDirectory
        let tempURL = tempDir.appendingPathComponent(
            ".codeforge-autosave-\(url.lastPathComponent)"
        )
        guard FileManager.default.fileExists(atPath: tempURL.path) else {
            return nil
        }
        guard let data = try? Data(contentsOf: tempURL),
              let content = String(data: data, encoding: .utf8) else {
            return nil
        }
        Self.logger.info("Recovered autosave for \(url.lastPathComponent)")
        return content
    }

    /// Remove autosave file after a successful explicit save.
    func clearAutosave(for url: URL) {
        let tempDir = FileManager.default.temporaryDirectory
        let tempURL = tempDir.appendingPathComponent(
            ".codeforge-autosave-\(url.lastPathComponent)"
        )
        try? FileManager.default.removeItem(at: tempURL)
    }

    // MARK: - Security-Scoped Bookmarks

    private func storeBookmark(for url: URL) {
        do {
            let bookmark = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            bookmarkDefaults.set(bookmark, forKey: "bookmark-\(url.path)")
            Self.logger.debug("Stored bookmark for \(url.lastPathComponent)")
        } catch {
            Self.logger.warning("Failed to store bookmark: \(error.localizedDescription)")
        }
    }

    /// Resolve a previously stored security-scoped bookmark.
    ///
    /// Starts security-scoped resource access on the returned URL.
    /// Caller must call `stopAccessing(_:)` when done with the file.
    func resolveBookmark(for path: String) -> URL? {
        guard let data = bookmarkDefaults.data(forKey: "bookmark-\(path)") else {
            return nil
        }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            return nil
        }
        if isStale {
            storeBookmark(for: url)
        }
        guard url.startAccessingSecurityScopedResource() else {
            Self.logger.warning("Failed to start security-scoped access for \(url.lastPathComponent)")
            return nil
        }
        return url
    }

    /// Stop security-scoped resource access for a URL.
    func stopAccessing(_ url: URL) {
        url.stopAccessingSecurityScopedResource()
    }
}
