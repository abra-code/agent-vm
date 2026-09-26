// Sources/AgentVMKit/Network/NetworkLogFollower.swift
//
// `box netlog --follow`: reads a box's network log as the proxy appends to it. Each `read()`
// returns the entries completed since the last one (the first returns what is there). The
// proxy moves a full log to `<name>.1` and starts a new file; the follower finishes the old
// file, then goes on with the new one from its start. A line still being written waits for its
// end, and unreadable lines are skipped, as `NetworkLog.entries` does.

import Darwin
import Foundation

public final class NetworkLogFollower {
    public let url: URL
    private var descriptor: Int32 = -1
    private var inode: ino_t = 0
    private var pending = Data()
    private let decoder: JSONDecoder

    public init(url: URL) {
        self.url = url
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    deinit {
        if descriptor >= 0 {
            close(descriptor)
        }
    }

    /// The entries completed since the last call.
    public func read() -> [NetworkLog.Entry] {
        var entries: [NetworkLog.Entry] = []
        if descriptor < 0 {
            open()
        }
        guard descriptor >= 0 else {
            return entries
        }
        entries += drain()
        // Rotated (or replaced): the new one is read from its start. The old file is read to
        // its end once more first, since the proxy may have finished writing to it after the
        // read above, before the move. A line the old file left unfinished is dropped.
        var current = stat()
        if lstat(url.path, &current) == 0, current.st_ino != inode {
            entries += drain()
            close(descriptor)
            descriptor = -1
            pending.removeAll()
            open()
            if descriptor >= 0 {
                entries += drain()
            }
        } else {
            // Cut short in place (not something agent-vm does): start over.
            var own = stat()
            if fstat(descriptor, &own) == 0, lseek(descriptor, 0, SEEK_CUR) > own.st_size {
                lseek(descriptor, 0, SEEK_SET)
                pending.removeAll()
            }
        }
        return entries
    }

    private func open() {
        let opened = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard opened >= 0 else {
            return
        }
        var info = stat()
        guard fstat(opened, &info) == 0 else {
            close(opened)
            return
        }
        descriptor = opened
        inode = info.st_ino
    }

    /// Reads to the end of the open file and decodes the complete lines.
    private func drain() -> [NetworkLog.Entry] {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0 && errno == EINTR {
                continue
            }
            guard count > 0 else {
                break
            }
            pending.append(contentsOf: buffer[0..<count])
        }
        var entries: [NetworkLog.Entry] = []
        var start = pending.startIndex
        while let newline = pending[start...].firstIndex(of: 10) {
            if let entry = try? decoder.decode(NetworkLog.Entry.self, from: pending[start..<newline]) {
                entries.append(entry)
            }
            start = newline + 1
        }
        // Once per read, not per line: a first read may hold the whole log (up to 64 MB).
        pending = Data(pending[start...])
        return entries
    }
}
