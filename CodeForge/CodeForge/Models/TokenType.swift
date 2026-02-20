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

    /// Dark theme color for this token type.
    var color: Color {
        switch self {
        case .keyword:     Color(red: 0.78, green: 0.46, blue: 0.82) // purple
        case .string:      Color(red: 0.90, green: 0.56, blue: 0.35) // orange
        case .comment:     Color(red: 0.42, green: 0.47, blue: 0.53) // gray
        case .function:    Color(red: 0.40, green: 0.72, blue: 0.93) // blue
        case .type:        Color(red: 0.38, green: 0.82, blue: 0.71) // teal
        case .number:      Color(red: 0.82, green: 0.77, blue: 0.47) // yellow
        case .operator:    Color(red: 0.78, green: 0.46, blue: 0.82) // purple
        case .punctuation: Color(white: 0.75)                        // light gray
        case .variable:    Color(white: 0.90)                        // near-white
        case .plain:       Color(white: 0.85)                        // off-white
        }
    }

    /// NSColor equivalent for applying to NSTextStorage.
    var nsColor: NSColor {
        NSColor(color)
    }
}
