// Sources/agent-vm/Printing.swift
//
// Everything agent-vm prints for a person passes through here. Much of what it shows is not its
// own text: a guest's answers, the output of programs in a box, the names of files an agent
// made, what recipe, pack and catalog files say. Printed as it is, such text can act on the
// terminal (replace the clipboard, retitle the window, erase the lines above it). So control
// characters are replaced on the way out; newlines and tabs stay, since agent-vm's own messages
// have them. Text that must not start a line of its own is made one line where it is put
// together (`Printable.line`). JSON output does not come this way: JSON escapes them itself.
// The lines agent-vm redraws in place (progress) are written to the terminal directly, with
// their text made one line first.

import AgentVMKit
import Foundation

/// `print` for this program: the standard one, with control characters replaced.
func print(_ items: Any..., separator: String = " ", terminator: String = "\n") {
    let text = items.map { "\($0)" }.joined(separator: separator)
    Swift.print(Printable.lines(text), terminator: terminator)
}

enum Stderr {
    /// Writes `text` (which brings its own line ends) to standard error, made printable.
    static func write(_ text: String) {
        FileHandle.standardError.write(Data(Printable.lines(text).utf8))
    }
}
