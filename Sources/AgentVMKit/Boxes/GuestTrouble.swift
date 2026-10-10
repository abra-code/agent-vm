// Sources/AgentVMKit/Boxes/GuestTrouble.swift
//
// What a Linux box's console says went wrong with the box itself, for the commands that would
// otherwise only say that the guest did not answer, or that an account does not exist: its
// kernel panicked (the supervisor stops such a box), or its file system reported errors and
// went read-only (then nothing in the box can be looked up or written, and every program is
// refused with "no such account").
//
// The console's text is the guest's. Only these fixed lines are looked for, and what is said
// is agent-vm's own words about the person's own box: nothing of the text is printed here.

import Foundation

public enum GuestTrouble: Sendable, Equatable {
    case kernelPanic
    case damagedDisk

    static let panicLine = "Kernel panic - not syncing"
    static let diskLines = ["EXT4-fs error", "Remounting filesystem read-only"]

    /// What the end of the box's console log says; nil for a macOS box (it has none), for a
    /// log that cannot be read, and when neither is there.
    public static func found(in box: Box) -> GuestTrouble? {
        guard box.record.effectiveGuest == .linux else {
            return nil
        }
        return found(inConsole: ConsoleLog.end(of: box.consoleLogURL))
    }

    static func found(inConsole text: String) -> GuestTrouble? {
        if text.contains(panicLine) {
            return .kernelPanic
        }
        if diskLines.contains(where: { text.contains($0) }) {
            return .damagedDisk
        }
        return nil
    }

    /// One line for the person, with what to do.
    public func words(for box: Box) -> String {
        switch self {
        case .kernelPanic:
            return "box \(box.name)'s kernel panicked, and the box was stopped (the reason is at the end of \(box.consoleLogURL.path)); "
                + "start it again with: agent-vm box start \(box.name)"
        case .damagedDisk:
            return "box \(box.name)'s console reports file system errors (\(box.consoleLogURL.path)): its disk is damaged; "
                + "make the box again with: agent-vm box recreate \(box.name) (what is only in the box is lost)"
        }
    }
}
