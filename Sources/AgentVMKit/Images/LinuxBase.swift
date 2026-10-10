// Sources/AgentVMKit/Images/LinuxBase.swift
//
// The Linux systems `image create --linux` knows: for each, the distribution's own cloud image
// and the checksum list beside it. The list is the root of trust: it is fetched over HTTPS from
// the distribution's host and from nowhere else, and the image (which a mirror may serve) is
// checked against it before anything reads it. Debian publishes no signature beside the list;
// Ubuntu does, and it is not checked (macOS has no tool for it).

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
    /// The image: a tar archive (xz) with one member, the raw disk (Debian), or a qcow2 file
    /// (Ubuntu). What a file is, is told by its first bytes (DiskUnpack).
    public var file: String
    public var checksumList: String
    /// The kind of checksum the list holds.
    public var digest: Digest
    /// The disk inside the archive; unused for a file that is no archive.
    public var member: String
    /// A small file beside the image that names its build, itself in the checksum list; nil
    /// when the distribution has none.
    public var manifest: String?
    /// The kernels the distribution packages, by the size of their memory pages. The first is
    /// the one its cloud image boots.
    public var kernels: [LinuxKernel]
    /// The page size an image of it gets when none is asked for.
    public var defaultPageBytes: Int

    /// The systems this agent-vm can build, newest of each distribution first.
    public static let known: [LinuxBase] = [
        LinuxBase(id: "debian-13", name: "Debian 13", distribution: "debian", version: "13",
                  folder: URL(string: "https://cloud.debian.org/images/cloud/trixie/latest/")!,
                  file: "debian-13-genericcloud-arm64.tar.xz", checksumList: "SHA512SUMS", digest: .sha512, member: "disk.raw",
                  manifest: "debian-13-genericcloud-arm64.json",
                  // On macOS 27.0 a guest kernel with 4 KiB pages loses memory of its own when the Mac
                  // pushes the guest's memory out (it reads as zeros, and the kernel faults); one with
                  // 16 KiB pages, the Mac's own page size, did not in the same test.
                  kernels: [LinuxKernel(pageBytes: 4096, package: "linux-image-cloud-arm64", flavor: "cloud-arm64"),
                            LinuxKernel(pageBytes: 16384, package: "linux-image-arm64-16k", flavor: "arm64-16k")],
                  defaultPageBytes: 16384),
        LinuxBase(id: "ubuntu-26.04", name: "Ubuntu 26.04", distribution: "ubuntu", version: "26.04",
                  folder: URL(string: "https://cloud-images.ubuntu.com/resolute/current/")!,
                  file: "resolute-server-cloudimg-arm64.img", checksumList: "SHA256SUMS", digest: .sha256, member: "",
                  manifest: nil,
                  // Ubuntu packages no kernel with 16 KiB pages.
                  kernels: [LinuxKernel(pageBytes: 4096, package: "linux-image-virtual", flavor: "generic")],
                  defaultPageBytes: 4096),
    ]

    /// A kind of checksum a distribution's list holds.
    public enum Digest: String, Sendable, Equatable {
        case sha512
        case sha256

        /// "SHA-512".
        public var name: String {
            return self == .sha512 ? "SHA-512" : "SHA-256"
        }

        /// How many hexadecimal digits one is written with.
        var hexDigits: Int {
            return self == .sha512 ? 128 : 64
        }
    }

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
        throw AgentVMError.linuxBase("--linux \(Printable.line(value, limit: 40)): this agent-vm knows \(known.map(\.id).joined(separator: ", ")) (\(distributions.joined(separator: " or ")) alone means its newest)")
    }

    /// The largest checksum list that is read: Debian's and Ubuntu's are 8 KB.
    static let listLimit = 64 << 10

    /// The checksum the list gives for `file`, in lower case. A list line is the digest in
    /// hexadecimal digits (128 for SHA-512, 64 for SHA-256), two spaces (or a space and "*"),
    /// and a file name; a line for `file` that is anything else, a second line for it, no line
    /// for it, or a list larger than `listLimit` is refused. Lines for other files are not
    /// looked at.
    static func digest(for file: String, inList text: String, kind: Digest = .sha512) throws -> String {
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
            guard digest.utf8.count == kind.hexDigits, digest.utf8.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) || ($0 >= 0x41 && $0 <= 0x46) }) else {
                throw ListProblem("the checksum list's line for \(file) does not start with a \(kind.name) (\(kind.hexDigits) hexadecimal digits)")
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

/// A kernel a distribution packages.
public struct LinuxKernel: Sendable, Equatable {
    /// The size of its memory pages: 4096, 16384 or 65536.
    public var pageBytes: Int
    /// The package that installs it and brings its updates: "linux-image-arm64-16k".
    public var package: String
    /// What the names of its packages end with: "arm64-16k", "cloud-arm64".
    public var flavor: String

    public init(pageBytes: Int, package: String, flavor: String) {
        self.pageBytes = pageBytes
        self.package = package
        self.flavor = flavor
    }
}

/// A kernel's page size as people write it and as an option takes it.
public enum LinuxPageSize {
    /// "16 KiB".
    public static func name(_ bytes: Int) -> String {
        return "\(bytes >> 10) KiB"
    }

    /// The bytes `--page-size <value>` names: "4k", "16k" or "64k", in either case.
    public static func bytes(_ value: String) -> Int? {
        switch value.lowercased() {
        case "4k": return 4096
        case "16k": return 16384
        case "64k": return 65536
        default: return nil
        }
    }

    /// What a guest's `getconf PAGESIZE` printed, when it is a size a kernel can have.
    static func parsed(_ text: String) -> Int? {
        guard let bytes = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)), [4096, 16384, 65536].contains(bytes) else {
            return nil
        }
        return bytes
    }
}

extension LinuxBase {
    /// The kernel with pages of that size, or a refusal that names the sizes there are.
    public func kernel(pageBytes: Int) throws -> LinuxKernel {
        guard let kernel = kernels.first(where: { $0.pageBytes == pageBytes }) else {
            let sizes = kernels.map { "\($0.pageBytes >> 10)k" }.joined(separator: " or ")
            throw AgentVMError.linuxBase("--page-size \(pageBytes >> 10)k: \(name) has \(kernels.count == 1 ? "only a kernel" : "kernels") with \(sizes) pages")
        }
        return kernel
    }

    /// The known system an image's record describes, whatever it was built from (a download, a
    /// file of the person's own, another image).
    public static func known(for system: LinuxSystem?) -> LinuxBase? {
        guard let system else {
            return nil
        }
        return known.first { $0.distribution == system.distribution && $0.version == system.version }
    }
}
