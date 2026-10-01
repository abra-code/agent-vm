// Sources/AgentVMKit/Printable.swift
//
// Text that agent-vm did not write, made safe to show: what a guest answers (its daemon's
// version, a refusal, a program's output quoted in an error, a notice), the names of files an
// agent made in a project, and what recipe, pack and catalog files say. Shown as it is, such
// text can drive the terminal it is printed on (replace the clipboard, retitle the window,
// erase and rewrite the lines above it) or forge lines of a log. Every control character and
// bidirectional override becomes "?".

import Foundation

public enum Printable {
    /// One line of text: every control character, a newline and a tab included, is replaced,
    /// so the text can neither act on a terminal nor start a line of its own. `limit` cuts a
    /// longer text, with "..." in place of the rest.
    public static func line(_ text: String, limit: Int? = nil) -> String {
        return clean(text, keeping: [], limit: limit)
    }

    /// Text of several lines: as `line`, but newlines and tabs stay. For whole messages that
    /// agent-vm composed around foreign text; what must not start a line of its own goes
    /// through `line` first.
    public static func lines(_ text: String, limit: Int? = nil) -> String {
        return clean(text, keeping: ["\n", "\t"], limit: limit)
    }

    /// Whether `text` is a version, build or feature name as agent-vm and macOS write them:
    /// 1 to `limit` ASCII letters, digits, ".", "+", "-" and "_".
    public static func isToken(_ text: String, limit: Int = 32) -> Bool {
        let scalars = text.unicodeScalars
        guard !scalars.isEmpty, scalars.count <= limit else {
            return false
        }
        return scalars.allSatisfy { scalar in
            switch scalar {
            case "a"..."z", "A"..."Z", "0"..."9", ".", "+", "-", "_":
                return true
            default:
                return false
            }
        }
    }

    private static func clean(_ text: String, keeping kept: Set<Unicode.Scalar>, limit: Int?) -> String {
        let scalars = text.unicodeScalars
        let tooLong = limit.map { scalars.count > $0 } ?? false
        guard tooLong || scalars.contains(where: { isControl($0) && !kept.contains($0) }) else {
            return text
        }
        var result = String.UnicodeScalarView()
        for scalar in tooLong ? scalars.prefix(limit ?? 0) : scalars[...] {
            result.append(isControl(scalar) && !kept.contains(scalar) ? "?" : scalar)
        }
        return String(result) + (tooLong ? "..." : "")
    }

    /// C0, DEL, C1 (a terminal reads U+009B as the start of a command, as it does ESC [), the
    /// line and paragraph separators, and the bidirectional marks, overrides and isolates, which
    /// show characters in another order than they are.
    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00..<0x20, 0x7F..<0xA0, 0x061C, 0x200E...0x200F, 0x2028...0x2029, 0x202A...0x202E, 0x2066...0x2069:
            return true
        default:
            return false
        }
    }
}
