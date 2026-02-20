import Foundation

/// Supported source languages for syntax highlighting.
enum SourceLanguage: String, Sendable {
    case swift = "swift"
    case python = "python"

    /// File extensions recognized for each language.
    var extensions: [String] {
        switch self {
        case .swift:  ["swift"]
        case .python: ["py"]
        }
    }

    /// Detect language from a file extension (without leading dot).
    static func from(extension ext: String) -> SourceLanguage? {
        switch ext.lowercased() {
        case "swift": .swift
        case "py":    .python
        default:      nil
        }
    }
}

/// Observable model backing the code editor view.
///
/// Tracks document content, cursor/selection state, language, and
/// syntax highlight ranges produced by ParsingActor.
@Observable
final class EditorModel {
    /// The full source text of the open document.
    var content: String = ""

    /// Current cursor position (UTF-16 offset for NSTextView compatibility).
    var cursorPosition: Int = 0

    /// Current selection range (UTF-16, location + length).
    var selection: NSRange = NSRange(location: 0, length: 0)

    /// Detected language based on file extension.
    var language: SourceLanguage?

    /// Whether the document has unsaved modifications.
    var isDirty: Bool = false

    /// The file URL of the currently open document, if any.
    var fileURL: URL?

    /// Syntax highlight ranges from the last TreeSitter parse.
    var highlightRanges: [HighlightRange] = []

    /// Whether a parse is currently in progress.
    var isParsing: Bool = false
}
