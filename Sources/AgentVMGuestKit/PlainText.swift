// Sources/AgentVMGuestKit/PlainText.swift
//
// The little text work the daemon needs, in plain Swift: the Linux daemon is built without the
// part of Foundation that has `trimmingCharacters(in:)` and `String(format:)` (Threads.swift
// says why).

enum PlainText {
    /// ASCII space, tab, line feed and carriage return.
    static let whitespace = " \t\n\r"

    /// `text` without the characters of `set` at its start and its end. Compared as Unicode
    /// scalars, so a carriage return goes also where it is one Character with a line feed.
    static func trimmed<Text: StringProtocol>(_ text: Text, of set: String = whitespace) -> String {
        let unwanted = Set(set.unicodeScalars)
        var scalars = text.unicodeScalars[...]
        while let first = scalars.first, unwanted.contains(first) {
            scalars = scalars.dropFirst()
        }
        while let last = scalars.last, unwanted.contains(last) {
            scalars = scalars.dropLast()
        }
        return String(String.UnicodeScalarView(scalars))
    }

    /// A number of seconds for a message: "20" and "0.5", not "20.0".
    static func number(_ value: Double) -> String {
        guard value.isFinite, value == value.rounded(), abs(value) < 1e15 else {
            return "\(value)"
        }
        return "\(Int(value))"
    }

    /// A number with one digit after the point: "3.0", "12.5".
    static func tenths(_ value: Double) -> String {
        guard value.isFinite, abs(value) < 1e15 else {
            return "\(value)"
        }
        return "\((value * 10).rounded() / 10)"
    }
}
