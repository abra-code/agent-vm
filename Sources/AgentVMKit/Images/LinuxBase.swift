// Sources/AgentVMKit/Images/LinuxBase.swift
//
// The Linux systems `image create --linux` knows: for each, the distribution's own cloud image
// and the checksum list beside it. The list is the root of trust: it is fetched over HTTPS from
// the distribution's host and from nowhere else, and the image (which a mirror may serve) is
// checked against it before anything reads it. Debian publishes no signature beside the list.

import Foundation

public struct LinuxBase: Sendable, Equatable {
    /// What `--linux` names and the image record keeps: "debian-13".
    public var id: String
    /// For messages: "Debian 13".
    public var name: String
    /// What the system must say of itself in /etc/os-release (ID and VERSION_ID).
    public var distribution: String
    public var version: String
    /// The folder the image and its checksum list are in; ends with "/".
    public var folder: URL
    /// The image: a tar archive (xz) with one member, the raw disk.
    public var file: String
    public var checksumList: String
    /// The disk inside the archive.
    public var member: String
    /// A small file beside the image that names its build, itself in the checksum list; nil
    /// when the distribution has none.
    public var manifest: String?

    /// The systems this agent-vm can build, newest of each distribution first.
    public static let known: [LinuxBase] = [
        LinuxBase(id: "debian-13", name: "Debian 13", distribution: "debian", version: "13",
                  folder: URL(string: "https://cloud.debian.org/images/cloud/trixie/latest/")!,
                  file: "debian-13-genericcloud-arm64.tar.xz", checksumList: "SHA512SUMS", member: "disk.raw",
                  manifest: "debian-13-genericcloud-arm64.json"),
    ]

    /// The system `--linux <value>` names: an id, or a distribution's name alone for its newest.
    public static func named(_ value: String) throws -> LinuxBase {
        if let base = known.first(where: { $0.id == value }) ?? known.first(where: { $0.distribution == value }) {
            return base
        }
        let distributions = known.reduce(into: [String]()) { list, base in
            if !list.contains(base.distribution) {
                list.append(base.distribution)
            }
        }
        let hint = distributions.map { "\($0) means the newest" }.joined(separator: ", ")
        throw AgentVMError.linuxBase("--linux \(Printable.line(value, limit: 40)): this agent-vm knows \(known.map(\.id).joined(separator: ", ")) (\(hint))")
    }

    /// The largest checksum list that is read: Debian's is 8 KB.
    static let listLimit = 64 << 10

    /// The SHA-512 the list gives for `file`, in lower case. A list line is 128 hexadecimal
    /// digits, two spaces (or a space and "*"), and a file name; a line for `file` that is
    /// anything else, a second line for it, no line for it, or a list larger than `listLimit`
    /// is refused. Lines for other files are not looked at.
    static func digest(for file: String, inList text: String) throws -> String {
        guard text.utf8.count <= listLimit else {
            throw ListProblem("the checksum list is larger than \(listLimit >> 10) KB")
        }
        var found: String?
        for line in text.split(whereSeparator: \.isNewline) {
            guard line.hasSuffix(file) else {
                continue
            }
            // "<digest>  <name>" or "<digest> *<name>": the name must be the whole of the rest.
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2 else {
                continue
            }
            var name = parts[1].drop(while: { $0 == " " })
            if name.hasPrefix("*") {
                name = name.dropFirst()
            }
            guard name == file else {
                continue
            }
            let digest = String(parts[0])
            guard digest.utf8.count == 128, digest.utf8.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) || ($0 >= 0x41 && $0 <= 0x46) }) else {
                throw ListProblem("the checksum list's line for \(file) does not start with a SHA-512 (128 hexadecimal digits)")
            }
            guard found == nil else {
                throw ListProblem("the checksum list names \(file) twice")
            }
            found = digest.lowercased()
        }
        guard let found else {
            throw ListProblem("the checksum list does not name \(file)")
        }
        return found
    }

    /// Why a checksum list cannot be used; the caller says whose list it is.
    struct ListProblem: Error, Equatable, CustomStringConvertible {
        var description: String

        init(_ description: String) {
            self.description = description
        }
    }
}
