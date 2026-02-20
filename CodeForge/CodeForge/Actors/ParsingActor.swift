import Foundation
import OSLog
import SwiftTreeSitter

/// Actor responsible for TreeSitter parsing on a background isolation domain.
///
/// Supports full parse and incremental re-parse for Swift and Python.
/// Produces `[HighlightRange]` from highlight queries applied to parse trees.
/// Streams results via `highlightStream` for the editor to consume.
actor ParsingActor {
    private let logger = Logger(subsystem: "com.codeforge.app", category: "parsing")

    private var parser: Parser?
    private var currentTree: MutableTree?
    private var currentLanguage: SourceLanguage?
    private var highlightQuery: Query?

    // Continuation for the highlight stream
    private var highlightContinuation: AsyncStream<[HighlightRange]>.Continuation?

    /// Stream of highlight ranges produced after each parse.
    nonisolated let highlightStream: AsyncStream<[HighlightRange]>

    init() {
        var continuation: AsyncStream<[HighlightRange]>.Continuation!
        highlightStream = AsyncStream { continuation = $0 }
        self.highlightContinuation = continuation
        logger.info("ParsingActor initialized")
    }

    // MARK: - Language Configuration

    /// Set the language for parsing. Loads grammar and highlight query.
    func setLanguage(_ language: SourceLanguage) throws {
        let tsLanguage: Language
        switch language {
        case .swift:
            tsLanguage = Language(language: tree_sitter_swift())
        case .python:
            tsLanguage = Language(language: tree_sitter_python())
        }

        let newParser = Parser()
        try newParser.setLanguage(tsLanguage)

        // Load highlight query from bundled .scm file
        let queryFileName: String
        switch language {
        case .swift:  queryFileName = "highlights-swift"
        case .python: queryFileName = "highlights-python"
        }

        guard let queryURL = Bundle.main.url(forResource: queryFileName, withExtension: "scm"),
              let queryData = try? Data(contentsOf: queryURL) else {
            logger.error("Failed to load highlight query for \(language.rawValue)")
            self.parser = newParser
            self.currentLanguage = language
            self.currentTree = nil
            self.highlightQuery = nil
            return
        }

        let query = try Query(language: tsLanguage, data: queryData)

        self.parser = newParser
        self.currentLanguage = language
        self.currentTree = nil
        self.highlightQuery = query

        logger.info("Language set to \(language.rawValue) with highlight query")
    }

    // MARK: - Full Parse

    /// Full parse of the entire source text. Resets any existing tree.
    func fullParse(source: String) {
        guard let parser else {
            logger.warning("fullParse called without a configured parser")
            return
        }

        currentTree = parser.parse(source)

        if currentTree == nil {
            logger.error("Full parse returned nil tree")
            return
        }

        let ranges = executeHighlightQuery(source: source)
        highlightContinuation?.yield(ranges)
        logger.debug("Full parse produced \(ranges.count) highlight ranges")
    }

    // MARK: - Incremental Parse

    /// Incremental re-parse after a text edit.
    ///
    /// - Parameters:
    ///   - source: The updated full source text after the edit.
    ///   - startByte: Byte offset where the edit begins.
    ///   - oldEndByte: Byte offset where the old text ended before the edit.
    ///   - newEndByte: Byte offset where the new text ends after the edit.
    ///   - startPoint: Row/column where the edit begins.
    ///   - oldEndPoint: Row/column where the old text ended.
    ///   - newEndPoint: Row/column where the new text ends.
    func incrementalParse(
        source: String,
        startByte: UInt32,
        oldEndByte: UInt32,
        newEndByte: UInt32,
        startPoint: Point,
        oldEndPoint: Point,
        newEndPoint: Point
    ) {
        guard let parser else {
            logger.warning("incrementalParse called without a configured parser")
            return
        }

        let inputEdit = InputEdit(
            startByte: startByte,
            oldEndByte: oldEndByte,
            newEndByte: newEndByte,
            startPoint: startPoint,
            oldEndPoint: oldEndPoint,
            newEndPoint: newEndPoint
        )

        // Apply edit to existing tree, then re-parse
        if currentTree != nil {
            currentTree?.edit(inputEdit)
            currentTree = parser.parse(tree: currentTree, string: source)
        } else {
            // No existing tree — fall back to full parse
            currentTree = parser.parse(source)
        }

        if currentTree == nil {
            logger.error("Incremental parse returned nil tree")
            return
        }

        let ranges = executeHighlightQuery(source: source)
        highlightContinuation?.yield(ranges)
        logger.debug("Incremental parse produced \(ranges.count) highlight ranges")
    }

    // MARK: - Incremental Edit + Deferred Re-parse

    /// Apply a text edit to the current tree without re-parsing.
    ///
    /// Call this immediately for each keystroke to keep the tree in sync.
    /// Then call `reParse(source:)` after a debounce interval.
    func applyEdit(
        startByte: UInt32,
        oldEndByte: UInt32,
        newEndByte: UInt32,
        startPoint: Point,
        oldEndPoint: Point,
        newEndPoint: Point
    ) {
        guard currentTree != nil else { return }
        let inputEdit = InputEdit(
            startByte: startByte,
            oldEndByte: oldEndByte,
            newEndByte: newEndByte,
            startPoint: startPoint,
            oldEndPoint: oldEndPoint,
            newEndPoint: newEndPoint
        )
        currentTree?.edit(inputEdit)
    }

    /// Re-parse the current (edited) tree and produce highlight ranges.
    ///
    /// Uses the tree's dirty regions for incremental parsing.
    /// Falls back to full parse if no tree exists.
    func reParse(source: String) {
        guard let parser else {
            logger.warning("reParse called without a configured parser")
            return
        }

        if currentTree != nil {
            currentTree = parser.parse(tree: currentTree, string: source)
        } else {
            currentTree = parser.parse(source)
        }

        guard currentTree != nil else {
            logger.error("Re-parse returned nil tree")
            return
        }

        let ranges = executeHighlightQuery(source: source)
        highlightContinuation?.yield(ranges)
        logger.debug("Re-parse produced \(ranges.count) highlight ranges")
    }

    // MARK: - Highlight Query Execution

    /// Execute the highlight query on the current tree and return ranges.
    private func executeHighlightQuery(source: String) -> [HighlightRange] {
        guard let tree = currentTree, let query = highlightQuery else {
            return []
        }

        let cursor = query.execute(in: tree)
        var ranges: [HighlightRange] = []

        while let match = cursor.next() {
            for capture in match.captures {
                guard let captureName = capture.name else { continue }

                let tokenType = mapCaptureToTokenType(captureName)
                let node = capture.node
                let startByte = Int(node.byteRange.lowerBound)
                let endByte = Int(node.byteRange.upperBound)

                guard endByte > startByte else { continue }

                ranges.append(HighlightRange(
                    startByte: startByte,
                    endByte: endByte,
                    tokenType: tokenType
                ))
            }
        }

        return ranges
    }

    /// Map a TreeSitter capture name (e.g. "keyword", "string.special") to our TokenType.
    private func mapCaptureToTokenType(_ name: String) -> TokenType {
        // TreeSitter capture names can be dotted (e.g. "keyword.function")
        // We match on the primary component
        let primary = name.split(separator: ".").first.map(String.init) ?? name

        switch primary {
        case "keyword", "repeat", "conditional", "include", "exception":
            return .keyword
        case "string":
            return .string
        case "comment":
            return .comment
        case "function", "method":
            return .function
        case "type", "constructor":
            return .type
        case "number", "float", "boolean":
            return .number
        case "operator":
            return .operator
        case "punctuation":
            return .punctuation
        case "variable", "parameter", "property", "field":
            return .variable
        default:
            return .plain
        }
    }

    // MARK: - Cleanup

    /// Reset parser state.
    func reset() {
        currentTree = nil
        highlightQuery = nil
        parser = nil
        currentLanguage = nil
    }

    deinit {
        highlightContinuation?.finish()
    }
}
