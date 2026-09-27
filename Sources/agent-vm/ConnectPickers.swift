// Sources/agent-vm/ConnectPickers.swift
//
// The boxes and images connect offers, as rows for the box picker (with its New box rows), the
// image picker and `connect list`, which shows what the pickers would; and the rows of the
// launch picker (the agents, then a login shell).
// Boxes come from their records and one status question per running box; never the space on
// disk, which would make the list slow.

import AgentVMKit
import Foundation
import TerminalUI

enum ConnectPickers {
    /// The New box rows' ids; no box can have them (a box name starts with a letter or digit).
    static let newTemporaryID = "+temporary"
    static let newKeptID = "+kept"

    /// A ready image a new box can be made from, and why not when it cannot.
    struct ImageOffer {
        var image: GoldenImage
        var reason: String?
    }

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
    static func boxSections(_ offers: [Offer], newBoxes: Bool, project: String?, remembered: ConnectChoice?) -> (sections: [PickerSection], selected: String?) {
        let running = offers.filter(\.running)
        let stopped = offers.filter { !$0.running }
        var sections: [PickerSection] = []
        if !running.isEmpty {
            sections.append(PickerSection(title: "Running", rows: running.map(row)))
        }
        if !stopped.isEmpty {
            sections.append(PickerSection(title: "Stopped", rows: stopped.map(row)))
        }
        let noImage = newBoxes ? nil : "no ready image"
        sections.append(PickerSection(title: "New box", rows: [
            PickerRow(id: newTemporaryID, columns: ["Temporary box from an image..."], note: noImage ?? "deleted when you leave", enabled: newBoxes),
            PickerRow(id: newKeptID, columns: ["Kept box from an image..."], note: noImage, enabled: newBoxes),
        ]))
        var selected: String?
        if remembered?.target == .box, let name = remembered?.box, offers.contains(where: { $0.box.name == name && $0.reason == nil }) {
            selected = name
        } else if remembered?.target == .temporary && newBoxes {
            selected = newTemporaryID
        } else if let project {
            selected = running.first { $0.reason == nil && $0.status.project == project }?.box.name
        }
        return (sections, selected)
    }

    // MARK: - What to run

    /// The launch picker's rows: each agent (its name, its command, its secret, its hosts),
    /// then the login shell. `installed` (a probe's answer) disables the agents it lacks; nil
    /// means not known yet (a stopped box), and every agent is offered.
    static func launchSections(_ agents: [AgentEntry], setSecrets: [String]?, installed: Set<String>?,
                               remembered: String?) -> (sections: [PickerSection], selected: String?) {
        var rows: [PickerRow] = []
        for agent in agents {
            var notes: [String] = []
            let missing = installed.map { !$0.contains(agent.command[0]) } ?? false
            if missing {
                notes.append("not installed")
            }
            if let secret = secretNote(agent, setSecrets: setSecrets) {
                notes.append(secret)
            }
            if !agent.allow.isEmpty {
                notes.append("allows: " + agent.allow.joined(separator: ", "))
            }
            rows.append(PickerRow(id: agent.id, columns: [agent.name, agent.command.joined(separator: " ")],
                                  note: notes.isEmpty ? nil : notes.joined(separator: "; "), enabled: !missing))
        }
        rows.append(PickerRow(id: AgentCatalog.shellID, columns: ["Login shell", "$SHELL -l"]))
        var selected: String?
        if let remembered, rows.contains(where: { $0.id == remembered && $0.enabled }) {
            selected = remembered
        }
        return ([PickerSection(title: nil, rows: rows)], selected)
    }

    /// "secret set", "needs one of: A, B", or nil (no secrets, or the Keychain could not be
    /// listed).
    static func secretNote(_ agent: AgentEntry, setSecrets: [String]?) -> String? {
        guard let setSecrets, !agent.secrets.isEmpty else {
            return nil
        }
        if agent.secrets.contains(where: { setSecrets.contains($0.name) }) {
            return "secret set"
        }
        let names = agent.secrets.map(\.name).joined(separator: ", ")
        return agent.secretsNeeded == .one ? "needs one of: \(names)" : "optional: \(names)"
    }

    /// The image picker's rows: name, macOS version, the recipe's description; an image whose
    /// guest daemon cannot run terminal sessions is shown but cannot be chosen.
    static func imageSections(_ images: [ImageOffer], remembered: String?) -> (sections: [PickerSection], selected: String?) {
        let rows = images.map { offer in
            PickerRow(id: offer.image.name, columns: [offer.image.name, "macOS \(offer.image.record.macOSVersion)", offer.image.record.recipe?.description ?? ""],
                      note: offer.reason, enabled: offer.reason == nil)
        }
        let selected = images.contains { $0.image.name == remembered && $0.reason == nil } ? remembered : nil
        return ([PickerSection(title: nil, rows: rows)], selected)
    }

    /// `connect list` for a person, and the plain list printed when there is no terminal to
    /// choose on.
    static func listLines(_ offers: [Offer], images: [ImageOffer] = [], project: String?, projectProblem: String?, remembered: ConnectChoice?) -> [String] {
        var lines: [String] = []
        if let project {
            var line = "Project: \(ConnectRunner.tilde(project))"
            if let remembered, remembered.target == .box, let box = remembered.box {
                line += " (remembered: box \(box)\(remembered.launch.map { ", " + launchName($0) } ?? ""))"
            } else if let remembered, remembered.target == .temporary, let image = remembered.image {
                line += " (remembered: a temporary box from \(image)\(remembered.launch.map { ", " + launchName($0) } ?? ""))"
            }
            lines.append(line)
        } else if let projectProblem {
            lines.append("Project: none (\(projectProblem))")
        } else {
            lines.append("Project: none")
        }
        if offers.isEmpty {
            lines.append("No boxes to connect to.")
            return lines + imageLines(images)
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
        return lines + imageLines(images)
    }

    /// The images section of `connect list`.
    static func imageLines(_ images: [ImageOffer]) -> [String] {
        guard !images.isEmpty else {
            return []
        }
        var lines = ["Images for a new box (new <image>)"]
        let width = images.map(\.image.name.count).max() ?? 0
        for offer in images {
            var line = "  " + offer.image.name.padding(toLength: width, withPad: " ", startingAt: 0) + "  macOS \(offer.image.record.macOSVersion)"
            if let reason = offer.reason {
                line += "  (\(reason))"
            } else if let description = offer.image.record.recipe?.description {
                line += "  " + description
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
        var images: [ImageEntry]

        private enum Keys: String, CodingKey {
            case project, projectProblem, remembered, boxes, images
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: Keys.self)
            try container.encode(project, forKey: .project)
            try container.encode(projectProblem, forKey: .projectProblem)
            try container.encode(remembered, forKey: .remembered)
            try container.encode(boxes, forKey: .boxes)
            try container.encode(images, forKey: .images)
        }
    }

    /// A ready image in `connect list --json`: every key present, null when it does not apply.
    struct ImageEntry: Encodable {
        var name: String
        var macOSVersion: String
        var description: String?
        var offered: Bool
        var reason: String?

        init(_ offer: ImageOffer) {
            name = offer.image.name
            macOSVersion = offer.image.record.macOSVersion
            description = offer.image.record.recipe?.description
            offered = offer.reason == nil
            reason = offer.reason
        }

        private enum Keys: String, CodingKey {
            case name, macOSVersion, description, offered, reason
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: Keys.self)
            try container.encode(name, forKey: .name)
            try container.encode(macOSVersion, forKey: .macOSVersion)
            try container.encode(description, forKey: .description)
            try container.encode(offered, forKey: .offered)
            try container.encode(reason, forKey: .reason)
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
