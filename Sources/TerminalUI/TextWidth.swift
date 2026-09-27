// Sources/TerminalUI/TextWidth.swift
//
// How many terminal columns text takes, so columns line up and no line reaches the window's
// edge. An approximation of what terminals do (wcwidth): combining marks and zero-width
// characters take none, East Asian wide and fullwidth characters and the common emoji take
// two, everything else one. Box and image names are ASCII; folder paths, descriptions and the
// typed filter may not be.

enum TextWidth {
    private static let wideRanges: [ClosedRange<UInt32>] = [
        0x1100...0x115F,
        0x2E80...0xA4CF,
        0xAC00...0xD7A3,
        0xF900...0xFAFF,
        0xFE30...0xFE4F,
        0xFF00...0xFF60,
        0xFFE0...0xFFE6,
        0x1F300...0x1F64F,
        0x1F900...0x1F9FF,
        0x20000...0x3FFFD,
    ]

    static func of(_ character: Character) -> Int {
        let scalars = character.unicodeScalars
        guard let first = scalars.first else {
            return 0
        }
        if scalars.allSatisfy(isZeroWidth) {
            return 0
        }
        if isControl(first) {
            // Control characters: never printed by the widgets (`printable` replaces them).
            return 0
        }
        return wideRanges.contains { $0.contains(first.value) } ? 2 : 1
    }

    static func of(_ text: String) -> Int {
        return text.reduce(0) { $0 + of($1) }
    }

    /// `text` cut by whole characters to at most `width` columns; a cut text ends in "..."
    /// when at least 4 columns remain for it.
    static func cut(_ text: String, to width: Int) -> String {
        guard width > 0 else {
            return ""
        }
        if of(text) <= width {
            return text
        }
        let room = width >= 4 ? width - 3 : width
        var result = ""
        var used = 0
        for character in text {
            let columns = of(character)
            if used + columns > room {
                break
            }
            result.append(character)
            used += columns
        }
        return width >= 4 ? result + "..." : result
    }

    /// `text` with every control character (C0, DEL, C1) and bidirectional override replaced by
    /// "?", so a folder name or a description can never move the cursor, send the terminal a
    /// command, or show its characters in another order than they are.
    static func printable(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: isControl) else {
            return text
        }
        var result = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            result.append(isControl(scalar) ? "?" : scalar)
        }
        return String(result)
    }

    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00..<0x20, 0x7F..<0xA0, 0x202A...0x202E, 0x2066...0x2069:
            return true
        default:
            return false
        }
    }

    private static func isZeroWidth(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x200B...0x200F, 0xFE00...0xFE0F:
            return true
        default:
            break
        }
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .enclosingMark:
            return true
        default:
            return false
        }
    }
}
