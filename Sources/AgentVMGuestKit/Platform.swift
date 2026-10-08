// Sources/AgentVMGuestKit/Platform.swift
//
// Where macOS and Linux differ for the guest daemon, in one place: the C library's module, the
// vsock address, the types posix_spawn takes, ioctl's request type, and what each system has
// for keeping descriptors and SIGPIPE away from the programs the daemon starts. The Linux
// daemon is built against musl (the static Linux SDK), so nothing here needs a library in
// the guest.

#if canImport(Darwin)
import Darwin
#elseif canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

#if !canImport(Darwin)
/// <linux/vm_sockets.h>, which the C library's module does not carry.
struct sockaddr_vm {
    var svm_family: sa_family_t = 0
    var svm_reserved1: UInt16 = 0
    var svm_port: UInt32 = 0
    var svm_cid: UInt32 = 0
    var svm_flags: UInt8 = 0
    var svm_zero: (UInt8, UInt8, UInt8) = (0, 0, 0)
}
#endif

enum Platform {
    typealias WindowSize = winsize

    // MARK: - Names that a type's own members hide (close, shutdown, listen, write)

    static func listen(_ descriptor: Int32, _ backlog: Int32) -> Int32 {
        #if canImport(Darwin)
        return Darwin.listen(descriptor, backlog)
        #elseif canImport(Musl)
        return Musl.listen(descriptor, backlog)
        #else
        return Glibc.listen(descriptor, backlog)
        #endif
    }

    static func shutdown(_ descriptor: Int32, _ how: Int32) -> Int32 {
        #if canImport(Darwin)
        return Darwin.shutdown(descriptor, how)
        #elseif canImport(Musl)
        return Musl.shutdown(descriptor, how)
        #else
        return Glibc.shutdown(descriptor, how)
        #endif
    }

    static func close(_ descriptor: Int32) {
        #if canImport(Darwin)
        _ = Darwin.close(descriptor)
        #elseif canImport(Musl)
        _ = Musl.close(descriptor)
        #else
        _ = Glibc.close(descriptor)
        #endif
    }

    static func write(_ descriptor: Int32, _ bytes: UnsafeRawPointer, _ count: Int) -> Int {
        #if canImport(Darwin)
        return Darwin.write(descriptor, bytes, count)
        #elseif canImport(Musl)
        return Musl.write(descriptor, bytes, count)
        #else
        return Glibc.write(descriptor, bytes, count)
        #endif
    }

    // MARK: - Terminals

    /// TIOCSWINSZ. Setting the size sends SIGWINCH to the terminal's foreground job.
    static func setWindowSize(_ descriptor: Int32, _ size: inout winsize) {
        #if canImport(Darwin)
        _ = ioctl(descriptor, TIOCSWINSZ, &size)
        #else
        _ = ioctl(descriptor, UInt(TIOCSWINSZ), &size)
        #endif
    }

    /// TIOCSCTTY: makes the terminal the calling session leader's controlling terminal.
    static func takeTerminal(_ descriptor: Int32) -> Int32 {
        #if canImport(Darwin)
        return ioctl(descriptor, TIOCSCTTY, 0)
        #else
        return ioctl(descriptor, UInt(TIOCSCTTY), CInt(0))
        #endif
    }

    // MARK: - posix_spawn

    #if canImport(Darwin)
    typealias SpawnAttributes = posix_spawnattr_t?
    typealias SpawnFileActions = posix_spawn_file_actions_t?

    static func emptyAttributes() -> SpawnAttributes {
        return nil
    }

    static func emptyActions() -> SpawnFileActions {
        return nil
    }

    /// A new session, default signals, an empty mask, and no descriptor inherited unless a file
    /// action names it.
    static let execSpawnFlags = Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT)

    static func addChangeDirectory(_ actions: inout SpawnFileActions, _ directory: String) {
        posix_spawn_file_actions_addchdir(&actions, directory)
    }
    #else
    typealias SpawnAttributes = posix_spawnattr_t
    typealias SpawnFileActions = posix_spawn_file_actions_t

    static func emptyAttributes() -> SpawnAttributes {
        return posix_spawnattr_t()
    }

    static func emptyActions() -> SpawnFileActions {
        return posix_spawn_file_actions_t()
    }

    /// Linux has no POSIX_SPAWN_CLOEXEC_DEFAULT: the daemon opens what it can close-on-exec,
    /// and the exec-as helper closes whatever else arrived (closeDescriptors).
    static let execSpawnFlags = Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)

    static func addChangeDirectory(_ actions: inout SpawnFileActions, _ directory: String) {
        posix_spawn_file_actions_addchdir_np(&actions, directory)
    }
    #endif

    // MARK: - SIGPIPE

    /// A socket whose peer went away gives EPIPE, not SIGPIPE. Linux has no such socket option:
    /// there the daemon ignores SIGPIPE as a whole.
    ///
    /// Both this and the descriptor's flag below are refused (EINVAL) for a socket that is
    /// already disconnected: one whose peer closed or reset before this was called (measured
    /// for a socket pair, an accepted Unix socket and TCP; a peer that only finished sending
    /// leaves the socket settable). Such a socket stays unprotected, and a write to it ends
    /// the process. So both say whether the socket is protected, and whoever writes must not
    /// write when it is not. A socket that got the setting while it was connected keeps it,
    /// and is refused all the same once disconnected: the flag is read back, the refusal alone
    /// is not the answer.
    @discardableResult
    static func noSIGPIPE(socket descriptor: Int32) -> Bool {
        #if canImport(Darwin)
        var one: Int32 = 1
        return setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size)) == 0
            || fcntl(descriptor, F_GETNOSIGPIPE) == 1
        #else
        return true
        #endif
    }

    /// The same for any descriptor (a pipe as well; for a socket it is the socket option under
    /// another name, refused in the same cases - measured). macOS only, as above.
    @discardableResult
    static func noSIGPIPE(descriptor: Int32) -> Bool {
        #if canImport(Darwin)
        return fcntl(descriptor, F_SETNOSIGPIPE, 1) == 0 || fcntl(descriptor, F_GETNOSIGPIPE) == 1
        #else
        return true
        #endif
    }

    // MARK: - Descriptors

    /// A pipe with both ends close-on-exec, or nil with errno set. On Linux the flag is set as
    /// the pipe is made, so no program started by another thread meanwhile can inherit an end.
    static func pipe() -> (read: Int32, write: Int32)? {
        var ends: [Int32] = [-1, -1]
        #if canImport(Darwin)
        guard Darwin.pipe(&ends) == 0 else {
            return nil
        }
        _ = fcntl(ends[0], F_SETFD, FD_CLOEXEC)
        _ = fcntl(ends[1], F_SETFD, FD_CLOEXEC)
        #else
        guard pipe2(&ends, O_CLOEXEC) == 0 else {
            return nil
        }
        #endif
        return (ends[0], ends[1])
    }

    /// A close-on-exec copy of `descriptor` numbered `minimum` or higher, or -1 with errno set.
    static func duplicate(_ descriptor: Int32, atLeast minimum: Int32) -> Int32 {
        return fcntl(descriptor, F_DUPFD_CLOEXEC, minimum)
    }

    /// Closes every open descriptor numbered `first` or higher. For the exec-as helper on
    /// Linux, a single-threaded process about to exec: whatever the daemon had open without
    /// close-on-exec must not reach the program. (The C library has no close_range function
    /// Swift can call.) Nothing on macOS, where posix_spawn already withheld them.
    static func closeDescriptors(from first: Int32) {
        #if !canImport(Darwin)
        if let names = try? FileManager.default.contentsOfDirectory(atPath: "/proc/self/fd") {
            // The listing's own descriptor is among the names; it is closed by now, and
            // closing a number that is not open is harmless here.
            for name in names {
                if let number = Int32(name), number >= first {
                    close(number)
                }
            }
            return
        }
        // No /proc: every number the limit allows.
        var limit = rlimit()
        let highest = getrlimit(RLIMIT_NOFILE, &limit) == 0 ? Int32(clamping: min(limit.rlim_cur, 65536)) : 1024
        var number = first
        while number < highest {
            close(number)
            number += 1
        }
        #endif
    }

    /// The daemon's unit keeps the kernel from choosing the daemon when memory runs out; a
    /// program it starts is an ordinary choice again. Linux only.
    static func resetOutOfMemoryScore() {
        #if !canImport(Darwin)
        let descriptor = open("/proc/self/oom_score_adj", O_WRONLY | O_CLOEXEC)
        if descriptor >= 0 {
            _ = write(descriptor, "0\n", 2)
            close(descriptor)
        }
        #endif
    }

    // MARK: - Accounts

    /// initgroups, whose group argument is signed on macOS.
    static func setGroups(of name: String, group: gid_t) -> Int32 {
        #if canImport(Darwin)
        return initgroups(name, Int32(bitPattern: group))
        #else
        return initgroups(name, group)
        #endif
    }

    // MARK: - The system

    /// What hello reports as the guest's build: macOS's build ("26A428"), or on Linux the
    /// VERSION_ID of /etc/os-release ("13" on Debian 13).
    static func systemVersion() -> String? {
        #if canImport(Darwin)
        var size = 0
        guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 0 else {
            return nil
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &buffer, &size, nil, 0) == 0 else {
            return nil
        }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        #else
        guard let text = try? String(contentsOfFile: "/etc/os-release", encoding: .utf8) else {
            return nil
        }
        return versionID(inOSRelease: text)
        #endif
    }

    /// VERSION_ID from the text of an os-release file, without its quotes; nil when there is
    /// none (a rolling release), it is empty, or it is not what a hello may carry as a build
    /// (Printable.isToken): a host refuses the whole hello over such a value.
    static func versionID(inOSRelease text: String) -> String? {
        for line in text.split(separator: "\n") where line.hasPrefix("VERSION_ID=") {
            let value = line.dropFirst("VERSION_ID=".count).trimmingCharacters(in: CharacterSet(charactersIn: "\"' \t\r"))
            return Printable.isToken(value) ? value : nil
        }
        return nil
    }
}
