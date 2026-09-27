// Sources/agent-vm/ConnectPickers.swift
//
// The boxes connect offers, as rows for the box picker and for `connect list`, which shows
// what the picker would. Built from the box records and one status question per running box;
// never the space on disk, which would make the list slow.

import AgentVMKit
import Foundation
import TerminalUI

enum ConnectPickers {
    /// A box the picker shows, and why it cannot be chosen when it cannot.
    struct Offer {
        var box: Box
        var status: BoxStatus
        /// Why the row is shown but cannot be chosen; nil: it can.
        var reason: String?

        var running: Bool {
            return status.state != .stopped
        }

        var temporary: Bool {
            return box.record.disposable == true
        }
    }

    /// The boxes offered: every box that is not stopped (an unresponsive one, or a temporary
    /// one that is stopping, disabled), then every stopped box that is not temporary. A stopped
    /// temporary box is garbage or another client's box about to start, never offered.
    static func offers(_ boxes: [(Box, BoxStatus)]) -> [Offer] {
        var running: [Offer] = []
        var stopped: [Offer] = []
        for (box, status) in boxes {
            var offer = Offer(box: box, status: status)
            switch status.state {
            case .stopped:
                if offer.temporary {
                    continue
                }
                stopped.append(offer)
                continue
            case .unresponsive:
                offer.reason = "unresponsive"
            case .stopping where offer.temporary:
                offer.reason = "stopping for good (temporary)"
            default:
                break
            }
            running.append(offer)
        }
        return running + stopped
    }

    /// The note after a row's columns: the shared folder, programs running, the owner.
    static func note(_ offer: Offer) -> String? {
        var parts: [String] = []
        if let reason = offer.reason {
            parts.append(reason)
        }
        if offer.running {
            let status = offer.status
            if let project = status.project {
                parts.append("project \(ConnectRunner.tilde(project))\(status.projectReadOnly == true ? " (read only)" : "")")
            }
            if let execs = status.activeExecs, execs > 0 {
                parts.append("\(execs) program\(execs == 1 ? "" : "s") running")
            }
            if offer.temporary {
                parts.append(status.ownerPid.map { "temporary, ends with process \($0)" } ?? "temporary")
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    static func row(_ offer: Offer) -> PickerRow {
        return PickerRow(id: offer.box.name, columns: [offer.box.name, offer.box.record.image, offer.status.state.rawValue],
                         note: note(offer), enabled: offer.reason == nil)
    }

    /// The picker's sections, and the row to start at: the remembered box, else the first
    /// running box sharing this folder.
    static func boxSections(_ offers: [Offer], project: String?, remembered: ConnectChoice?) -> (sections: [PickerSection], selected: String?) {
        let running = offers.filter(\.running)
        let stopped = offers.filter { !$0.running }
        var sections: [PickerSection] = []
        if !running.isEmpty {
            sections.append(PickerSection(title: "Running", rows: running.map(row)))
        }
        if !stopped.isEmpty {
            sections.append(PickerSection(title: "Stopped", rows: stopped.map(row)))
        }
        var selected: String?
        if remembered?.target == .box, let name = remembered?.box, offers.contains(where: { $0.box.name == name && $0.reason == nil }) {
            selected = name
        } else if let project {
            selected = running.first { $0.reason == nil && $0.status.project == project }?.box.name
        }
        return (sections, selected)
    }

    /// `connect list` for a person, and the plain list printed when there is no terminal to
    /// choose on.
    static func listLines(_ offers: [Offer], project: String?, projectProblem: String?, remembered: ConnectChoice?) -> [String] {
        var lines: [String] = []
        if let project {
            var line = "Project: \(ConnectRunner.tilde(project))"
            if let remembered, remembered.target == .box, let box = remembered.box {
                line += " (remembered: box \(box)\(remembered.launch.map { ", " + launchName($0) } ?? ""))"
            }
            lines.append(line)
        } else if let projectProblem {
            lines.append("Project: none (\(projectProblem))")
        } else {
            lines.append("Project: none")
        }
        if offers.isEmpty {
            lines.append("No boxes to connect to.")
            return lines
        }
        let widths = [offers.map(\.box.name.count).max() ?? 0, offers.map(\.box.record.image.count).max() ?? 0,
                      offers.map(\.status.state.rawValue.count).max() ?? 0]
        func pad(_ text: String, _ width: Int) -> String {
            return text.padding(toLength: max(width, text.count), withPad: " ", startingAt: 0)
        }
        var section: Bool?
        for offer in offers {
            if section != offer.running {
                section = offer.running
                lines.append(offer.running ? "Running" : "Stopped")
            }
            var line = "  \(pad(offer.box.name, widths[0]))  \(pad(offer.box.record.image, widths[1]))  \(pad(offer.status.state.rawValue, widths[2]))"
            if let note = note(offer) {
                line += "  " + (offer.reason == nil ? note : "(\(note))")
            }
            while line.hasSuffix(" ") {
                line.removeLast()
            }
            lines.append(line)
        }
        return lines
    }

    /// What was run, for a person.
    static func launchName(_ launch: String) -> String {
        return launch == "shell" ? "login shell" : launch
    }

    /// `connect list --json`: every key present, null when it does not apply.
    struct ListJSON: Encodable {
        var project: String?
        var projectProblem: String?
        var remembered: ConnectChoice?
        var boxes: [BoxEntry]

        private enum Keys: String, CodingKey {
            case project, projectProblem, remembered, boxes
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: Keys.self)
            try container.encode(project, forKey: .project)
            try container.encode(projectProblem, forKey: .projectProblem)
            try container.encode(remembered, forKey: .remembered)
            try container.encode(boxes, forKey: .boxes)
        }
    }

    struct BoxEntry: Encodable {
        var name: String
        var image: String
        var state: String
        var temporary: Bool
        var project: String?
        var projectReadOnly: Bool?
        var activeExecs: Int?
        var ownerPid: Int32?
        var offered: Bool
        var reason: String?

        init(_ offer: Offer) {
            name = offer.box.name
            image = offer.box.record.image
            state = offer.status.state.rawValue
            temporary = offer.temporary
            project = offer.status.project
            projectReadOnly = offer.status.project == nil ? nil : offer.status.projectReadOnly == true
            activeExecs = offer.running ? offer.status.activeExecs : nil
            ownerPid = offer.status.ownerPid
            offered = offer.reason == nil
            reason = offer.reason
        }

        private enum Keys: String, CodingKey {
            case name, image, state, temporary, project, projectReadOnly, activeExecs, ownerPid, offered, reason
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: Keys.self)
            try container.encode(name, forKey: .name)
            try container.encode(image, forKey: .image)
            try container.encode(state, forKey: .state)
            try container.encode(temporary, forKey: .temporary)
            try container.encode(project, forKey: .project)
            try container.encode(projectReadOnly, forKey: .projectReadOnly)
            try container.encode(activeExecs, forKey: .activeExecs)
            try container.encode(ownerPid, forKey: .ownerPid)
            try container.encode(offered, forKey: .offered)
            try container.encode(reason, forKey: .reason)
        }
    }
}
