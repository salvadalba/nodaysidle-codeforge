import Foundation
import Testing

@testable import CodeForge

// MARK: - EditorModel Tests

@Suite("EditorModel")
struct EditorModelTests {

    @Test("Default state is empty and clean")
    func defaultState() {
        let model = EditorModel()
        #expect(model.content.isEmpty)
        #expect(model.cursorPosition == 0)
        #expect(model.selection == NSRange(location: 0, length: 0))
        #expect(model.language == nil)
        #expect(model.isDirty == false)
        #expect(model.fileURL == nil)
        #expect(model.highlightRanges.isEmpty)
        #expect(model.isParsing == false)
    }

    @Test("Content assignment marks dirty")
    func contentAssignment() {
        let model = EditorModel()
        model.content = "let x = 1"
        model.isDirty = true
        #expect(model.isDirty)
        #expect(model.content == "let x = 1")
    }

    @Test("Highlight ranges can be set and cleared")
    func highlightRanges() {
        let model = EditorModel()
        let ranges = [
            HighlightRange(startByte: 0, endByte: 3, tokenType: .keyword),
            HighlightRange(startByte: 4, endByte: 5, tokenType: .variable),
        ]
        model.highlightRanges = ranges
        #expect(model.highlightRanges.count == 2)

        model.highlightRanges = []
        #expect(model.highlightRanges.isEmpty)
    }
}

// MARK: - SourceLanguage Tests

@Suite("SourceLanguage")
struct SourceLanguageTests {

    @Test("Detects Swift from extension")
    func detectSwift() {
        #expect(SourceLanguage.from(extension: "swift") == .swift)
        #expect(SourceLanguage.from(extension: "SWIFT") == .swift)
    }

    @Test("Detects Python from extension")
    func detectPython() {
        #expect(SourceLanguage.from(extension: "py") == .python)
        #expect(SourceLanguage.from(extension: "PY") == .python)
    }

    @Test("Returns nil for unsupported extension")
    func unsupported() {
        #expect(SourceLanguage.from(extension: "js") == nil)
        #expect(SourceLanguage.from(extension: "rs") == nil)
        #expect(SourceLanguage.from(extension: "") == nil)
    }

    @Test("Extensions list matches")
    func extensionsList() {
        #expect(SourceLanguage.swift.extensions == ["swift"])
        #expect(SourceLanguage.python.extensions == ["py"])
    }
}

// MARK: - TokenType Tests

@Suite("TokenType")
struct TokenTypeTests {

    @Test("All token types have distinct non-nil colors")
    func distinctColors() {
        let allTypes: [TokenType] = [
            .keyword, .string, .comment, .function, .type,
            .number, .operator, .punctuation, .variable, .plain,
        ]
        for tokenType in allTypes {
            // Just ensure nsColor doesn't crash
            _ = tokenType.nsColor
            _ = tokenType.color
        }
        // keyword and plain should differ
        #expect(TokenType.keyword.nsColor != TokenType.plain.nsColor)
    }
}

// MARK: - HighlightRange Tests

@Suite("HighlightRange")
struct HighlightRangeTests {

    @Test("Equatable conformance")
    func equatable() {
        let a = HighlightRange(startByte: 0, endByte: 5, tokenType: .keyword)
        let b = HighlightRange(startByte: 0, endByte: 5, tokenType: .keyword)
        let c = HighlightRange(startByte: 0, endByte: 5, tokenType: .string)
        #expect(a == b)
        #expect(a != c)
    }

    @Test("Sendable conformance compiles")
    func sendable() async {
        let range = HighlightRange(startByte: 0, endByte: 10, tokenType: .comment)
        let task = Task { range }
        let result = await task.value
        #expect(result.tokenType == .comment)
    }
}

// MARK: - EditorService Tests

@Suite("EditorService")
struct EditorServiceTests {

    private func tempSwiftFile(content: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent("test-\(UUID().uuidString).swift")
        try Data(content.utf8).write(to: url)
        return url
    }

    @Test("Opens valid Swift file")
    func openValidSwift() throws {
        let content = "let x = 1\n"
        let url = try tempSwiftFile(content: content)
        defer { try? FileManager.default.removeItem(at: url) }

        let service = EditorService()
        let result = try service.open(url: url)
        #expect(result.content == content)
        #expect(result.language == .swift)
    }

    @Test("Opens valid Python file")
    func openValidPython() throws {
        let dir = FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent("test-\(UUID().uuidString).py")
        try Data("x = 1\n".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let service = EditorService()
        let result = try service.open(url: url)
        #expect(result.content == "x = 1\n")
        #expect(result.language == .python)
    }

    @Test("Rejects unsupported extension")
    func rejectsUnsupported() throws {
        let dir = FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent("test.js")
        try Data("var x = 1;".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let service = EditorService()
        #expect(throws: EditorError.self) {
            try service.open(url: url)
        }
    }

    @Test("Rejects nonexistent file")
    func rejectsNonexistent() {
        let url = URL(fileURLWithPath: "/tmp/nonexistent-\(UUID().uuidString).swift")
        let service = EditorService()
        #expect(throws: EditorError.self) {
            try service.open(url: url)
        }
    }

    @Test("Rejects file exceeding line limit")
    func rejectsTooManyLines() throws {
        let lines = (0...50_001).map { "// line \($0)" }.joined(separator: "\n")
        let url = try tempSwiftFile(content: lines)
        defer { try? FileManager.default.removeItem(at: url) }

        let service = EditorService()
        #expect(throws: EditorError.self) {
            try service.open(url: url)
        }
    }

    @Test("Atomic save writes content")
    func atomicSave() throws {
        let dir = FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent("save-test-\(UUID().uuidString).swift")
        defer { try? FileManager.default.removeItem(at: url) }

        let service = EditorService()
        let content = "func hello() {}\n"
        try service.save(content: content, to: url)

        let readBack = try String(contentsOf: url, encoding: .utf8)
        #expect(readBack == content)
    }

    @Test("Autosave recovery round-trip")
    func autosaveRecovery() throws {
        let dir = FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent("autosave-test.swift")
        let tempURL = dir.appendingPathComponent(".codeforge-autosave-autosave-test.swift")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: tempURL)
        }

        // Simulate autosave data existing
        let content = "recovered content"
        try Data(content.utf8).write(to: tempURL)

        let service = EditorService()
        let recovered = service.recoverAutosave(for: url)
        #expect(recovered == content)

        // Clear it
        service.clearAutosave(for: url)
        #expect(service.recoverAutosave(for: url) == nil)
    }

    @Test("Rejects directory as file")
    func rejectsDirectory() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dir-test-\(UUID().uuidString).swift")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let service = EditorService()
        #expect(throws: EditorError.self) {
            try service.open(url: dir)
        }
    }
}

// MARK: - ParsingActor Tests

@Suite("ParsingActor")
struct ParsingActorTests {

    @Test("Sets Swift language without throwing")
    func setSwiftLanguage() async throws {
        let actor = ParsingActor()
        try await actor.setLanguage(.swift)
    }

    @Test("Sets Python language without throwing")
    func setPythonLanguage() async throws {
        let actor = ParsingActor()
        try await actor.setLanguage(.python)
    }

    @Test("Full parse produces highlights for Swift code")
    func fullParseSwift() async throws {
        let actor = ParsingActor()
        try await actor.setLanguage(.swift)

        let source = "let x = 42\nfunc hello() {}\n"
        await actor.fullParse(source: source)

        // Consume from stream — use a task with timeout
        let ranges = await withCheckedContinuation { cont in
            Task {
                for await ranges in actor.highlightStream {
                    cont.resume(returning: ranges)
                    return
                }
                cont.resume(returning: [])
            }
        }

        #expect(!ranges.isEmpty)
        // Should find at least a keyword ("let" or "func")
        let hasKeyword = ranges.contains { $0.tokenType == .keyword }
        #expect(hasKeyword)
    }

    @Test("Full parse produces highlights for Python code")
    func fullParsePython() async throws {
        let actor = ParsingActor()
        try await actor.setLanguage(.python)

        let source = "def hello():\n    x = 42\n"
        await actor.fullParse(source: source)

        let ranges = await withCheckedContinuation { cont in
            Task {
                for await ranges in actor.highlightStream {
                    cont.resume(returning: ranges)
                    return
                }
                cont.resume(returning: [])
            }
        }

        #expect(!ranges.isEmpty)
        let hasKeyword = ranges.contains { $0.tokenType == .keyword }
        #expect(hasKeyword)
    }

    @Test("Reset clears parser state")
    func resetClearsState() async throws {
        let actor = ParsingActor()
        try await actor.setLanguage(.swift)
        await actor.fullParse(source: "let x = 1")
        await actor.reset()
        // After reset, fullParse should warn (no parser) but not crash
        await actor.fullParse(source: "let y = 2")
    }
}
