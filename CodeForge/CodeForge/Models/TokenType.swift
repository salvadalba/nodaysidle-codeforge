import SwiftUI

/// Syntax token types produced by TreeSitter highlight queries.
enum TokenType: String, Sendable, CaseIterable {
    case keyword
    case string
    case comment
    case function
    case type
    case number
    case `operator`
    case punctuation
    case variable
    case plain

    /// Dark theme color for this token type — UI brightness fix.
    var color: Color {
        switch self {
        case .keyword:     Color(red: 0.82, green: 0.50, blue: 0.88) // purple, brighter
        case .string:      Color(red: 0.94, green: 0.60, blue: 0.38) // orange, warmer
        case .comment:     Color(red: 0.50, green: 0.56, blue: 0.62) // gray, more visible
        case .function:    Color(red: 0.45, green: 0.76, blue: 0.96) // blue, brighter
        case .type:        Color(red: 0.42, green: 0.86, blue: 0.76) // teal, brighter
        case .number:      Color(red: 0.86, green: 0.82, blue: 0.52) // yellow, warmer
        case .operator:    Color(red: 0.82, green: 0.50, blue: 0.88) // purple
        case .punctuation: Color(white: 0.78)                        // light gray, brighter
        case .variable:    Color(white: 0.92)                        // near-white
        case .plain:       Color(white: 0.90)                        // off-white
        }
    }

    /// NSColor equivalent for applying to NSTextStorage.
    var nsColor: NSColor {
        NSColor(color)
    }
}
