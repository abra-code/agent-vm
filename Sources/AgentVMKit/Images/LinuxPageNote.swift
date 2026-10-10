// Sources/AgentVMKit/Images/LinuxPageNote.swift
//
// What agent-vm says of a Linux image or box whose kernel has memory pages smaller than the
// Mac's 16 KiB. On macOS 27.0 such a guest can lose memory of its kernel's own when the Mac runs
// short of memory and pushes the guest's memory out: the kernel then meets a fault and the box
// stops. A kernel with 16 KiB pages did not show it (Docs/linux-boxes.md, "The kernel's page
// size"). The words are here so that doctor, a box's start and an image's build say the same.

import Foundation

public enum LinuxPageNote {
    /// The Mac's own page size; a guest kernel with pages of this size or larger is not noted.
    public static let hostPageBytes = 16384

    /// Whether a system's kernel has pages smaller than the Mac's. A record that names no size
    /// was written before sizes were kept, when every image booted its cloud image's kernel:
    /// 4 KiB pages.
    public static func hasSmallPages(_ system: LinuxSystem?) -> Bool {
        guard let system else {
            return false
        }
        return (system.pageSize ?? 4096) < hostPageBytes
    }

    /// Whether agent-vm knows a kernel with pages of the Mac's size or larger for the system.
    public static func hasLargerKernel(_ system: LinuxSystem?) -> Bool {
        return LinuxBase.known(for: system)?.kernels.contains { $0.pageBytes >= hostPageBytes } ?? false
    }

    static let risk = "can lose kernel memory and stop when the Mac runs short of memory (macOS 27)"

    /// For a box that is being started; nil when its kernel's pages are not small. `image` is
    /// the image the box was made from. A box that is not kept (it is deleted when its session
    /// ends) is not told to recreate itself: the next one is made from the updated image.
    public static func forBox(_ name: String, system: LinuxSystem?, image: String, kept: Bool = true) -> String? {
        guard hasSmallPages(system) else {
            return nil
        }
        let remedy = hasLargerKernel(system)
            ? "`agent-vm image update \(image) --system --page-size 16k`\(kept ? ", then `agent-vm box recreate \(name)`," : "") gives \(kept ? "it" : "the next box of \(image)") the kernel with 16 KiB pages"
            : "\(system?.shortName ?? "its system") packages no kernel with 16 KiB pages; a Debian box has one"
        return "box \(name)'s kernel has 4 KiB memory pages and \(risk); \(remedy)"
    }

    /// For an image that is about to be built with a kernel of `pageBytes`; nil when they are
    /// not small.
    public static func forBuild(_ base: LinuxBase, pageBytes: Int) -> String? {
        guard pageBytes < hostPageBytes else {
            return nil
        }
        let larger = base.kernels.contains { $0.pageBytes >= hostPageBytes }
        let remedy = larger ? "leave out --page-size for the kernel with 16 KiB pages" : "\(base.name) packages no kernel with 16 KiB pages; Debian does"
        return "a box of this image has a kernel with \(LinuxPageSize.name(pageBytes)) memory pages and \(risk); \(remedy)"
    }

    /// A ready Linux image whose kernel has small pages, for doctor.
    public struct Image: Sendable, Equatable, Codable {
        public var name: String
        /// "Debian 13".
        public var system: String
        /// Whether a system update gives it a kernel with 16 KiB pages.
        public var canSwitch: Bool

        public init(name: String, system: String, canSwitch: Bool) {
            self.name = name
            self.system = system
            self.canSwitch = canSwitch
        }
    }

    /// The store's ready Linux images whose kernels have small pages, by name.
    public static func images(in store: ImageStore) -> [Image] {
        let images = (try? store.list().images) ?? []
        return images.filter { $0.record.state == .ready && $0.record.effectiveGuest == .linux && hasSmallPages($0.record.linux) }
            .map { Image(name: $0.name, system: $0.record.systemShort, canSwitch: hasLargerKernel($0.record.linux)) }
            .sorted { $0.name < $1.name }
    }

    /// Doctor's line for those images; nil when there is none.
    public static func forDoctor(_ images: [Image]) -> String? {
        guard !images.isEmpty else {
            return nil
        }
        let names = images.map { "\($0.name) (\($0.system))" }.joined(separator: ", ")
        let movable = images.filter(\.canSwitch).map(\.name)
        var text = "\(images.count == 1 ? "image" : "images") \(names): a kernel with 4 KiB memory pages, and a box of \(images.count == 1 ? "it" : "them") \(risk)"
        if !movable.isEmpty {
            text += "; `agent-vm image update \(movable.joined(separator: " ")) --system --page-size 16k` gives \(movable.count == 1 ? "it" : "them") the kernel with 16 KiB pages (then `box recreate` for each box)"
        }
        let fixed = images.filter { !$0.canSwitch }.map(\.system).reduce(into: [String]()) { list, system in
            if !list.contains(system) {
                list.append(system)
            }
        }
        if !fixed.isEmpty {
            text += "; \(fixed.joined(separator: " and ")) \(fixed.count == 1 ? "packages" : "package") no such kernel"
        }
        return text
    }
}
