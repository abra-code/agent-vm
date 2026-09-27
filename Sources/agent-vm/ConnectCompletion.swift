// Sources/agent-vm/ConnectCompletion.swift
//
// Shell completion for connect (and avm): box names, the images a new box can be made from, and
// agent ids, read from the store when the shell asks (ArgumentParser runs these closures for its
// generated zsh, bash and fish scripts). A store that cannot be read completes nothing; it is
// never an error, which the shell would print in the middle of the line.

import AgentVMKit
import ArgumentParser
import Foundation

enum ConnectCompletion {
    /// The boxes connect can take: every box but a stopped temporary one, which is not started
    /// again.
    static let boxes = CompletionKind.custom { _, _, prefix in
        let boxes = (try? BoxStore(root: SessionStore.defaultRoot()).list().boxes) ?? []
        return matching(boxes.filter { $0.record.disposable != true || $0.isRunning }.map(\.name), prefix)
    }

    /// Ready images whose guest daemon runs terminal sessions.
    static let images = CompletionKind.custom { _, _, prefix in
        let images = (try? ImageStore(root: SessionStore.defaultRoot()).list().images) ?? []
        let usable = images.filter { $0.record.state == .ready && ($0.record.guestFeatures ?? []).contains(GuestFeature.terminal) }
        return matching(usable.map(\.name), prefix)
    }

    /// The agents' ids, built-in and the user's.
    static let agents = CompletionKind.custom { _, _, prefix in
        return matching(AgentCatalog.load(store: SessionStore.defaultRoot()).entries.map(\.id), prefix)
    }

    /// `names` that start with `prefix`, sorted.
    static func matching(_ names: [String], _ prefix: String) -> [String] {
        return names.filter { $0.hasPrefix(prefix) }.sorted()
    }
}
