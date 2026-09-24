// Tests/AgentVMKitTests/PromptWatcherTests.swift
//
// Permission prompt notices: the privacy-service log lines the guest daemon reads (as macOS 27
// writes them), the names a notice gives, the client taking a notice frame, and the exec log
// keeping what a program waited on.

import Darwin
import Foundation
import Testing
@testable import AgentVMKit

@Suite struct PromptWatcherTests {
    /// Lines logged for `ls ~/Downloads` run by exec in a box without Full Disk Access.
    let attribution = "AUTHREQ_ATTRIBUTION: msgID=152.31, attribution={responsible={TCCDProcess: identifier=com.abracode.agent-vm-guest, pid=291, auid=0, euid=0, responsible_path=/usr/local/libexec/agent-vm-guest, binary_path=/usr/local/libexec/agent-vm-guest}, accessing={TCCDProcess: identifier=com.apple.ls, pid=688, auid=501, euid=501, binary_path=/bin/ls}, requesting={TCCDProcess: identifier=com.apple.sandboxd, pid=152, auid=0, euid=0, binary_path=/usr/libexec/sandboxd}, },"
    let prompting = "AUTHREQ_PROMPTING: msgID=152.31, service=kTCCServiceSystemPolicyDownloadsFolder, subject=Sub:{/usr/local/libexec/agent-vm-guest}Resp:{TCCDProcess: identifier=com.abracode.agent-vm-guest, pid=291, auid=0, euid=0, responsible_path=/usr/local/libexec/agent-vm-guest, binary_path=/usr/local/libexec/agent-vm-guest},"

    @Test func realLogLinesAreRead() {
        #expect(PromptWatcher.parse(attribution) == .attribution(messageID: "152.31", pid: 688, program: "/bin/ls"))
        #expect(PromptWatcher.parse(prompting) == .prompting(messageID: "152.31", service: "kTCCServiceSystemPolicyDownloadsFolder"))
        // A program asking itself (as logged on macOS 27): no `accessing`, the program is `requesting`.
        let asking = "AUTHREQ_ATTRIBUTION: msgID=87075.1, attribution={responsible={TCCDProcess: identifier=com.abracode.agent-vm-guest, pid=291, auid=0, euid=0, responsible_path=/usr/local/libexec/agent-vm-guest, binary_path=/usr/local/libexec/agent-vm-guest}, requesting={TCCDProcess: identifier=com.apple.osascript, pid=87075, auid=501, euid=501, binary_path=/usr/bin/osascript}, },"
        #expect(PromptWatcher.parse(asking) == .attribution(messageID: "87075.1", pid: 87075, program: "/usr/bin/osascript"))
    }

    @Test func otherLinesAreNotEvents() {
        for line in ["AUTHREQ_SUBJECT: msgID=152.31, subject=/usr/local/libexec/agent-vm-guest,",
                     "AUTHREQ_ATTRIBUTION: msgID=1.1, attribution={requesting={TCCDProcess: identifier=x}, },",
                     "AUTHREQ_PROMPTING: service=kTCCServiceCamera,",
                     "Platform binary prompting is 'Deny' because: is Platform Binary",
                     ""] {
            #expect(PromptWatcher.parse(line) == nil, "\(line)")
        }
    }

    @Test func noticesNameWhatTheyWaitOn() {
        #expect(GuestNotice(kind: .permissionPrompt, service: "kTCCServiceSystemPolicyDownloadsFolder").serviceDescription == "the Downloads folder")
        #expect(GuestNotice(kind: .permissionPrompt, service: "kTCCServiceAppleEvents").serviceDescription == "control of another app (Automation)")
        #expect(GuestNotice(kind: .permissionPrompt, service: "kTCCServiceSomethingNew").serviceDescription == "kTCCServiceSomethingNew")
        #expect(GuestNotice(kind: .permissionPrompt).serviceDescription == "something macOS protects")
    }

    /// A guest that answers, sends a notice (and one the host cannot read), output, and exits.
    @Test func theClientTakesNoticesBesideTheOutput() throws {
        var pair: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        defer { close(pair[0]); close(pair[1]) }
        let guest = FrameChannel(descriptor: pair[1])
        Thread.detachNewThread {
            _ = try? guest.receive()
            try? guest.send(.response, json: GuestResponse(ok: true, v: AgentVM.guestProtocolVersion, pid: 42))
            try? guest.send(.notice, json: GuestNotice(kind: .permissionPrompt, service: "kTCCServiceSystemPolicyDownloadsFolder", program: "/bin/ls", pid: 43))
            try? guest.send(Frame(.notice, Array("not json".utf8)))
            try? guest.send(Frame(.stdout, Array("out".utf8)))
            try? guest.send(.exit, json: ExitReport(status: 0))
        }
        let session = try ExecSession(descriptor: pair[0], request: GuestRequest(op: .exec, argv: ["/bin/ls"], notices: true))
        var notices: [GuestNotice] = []
        var output = Data()
        let report = try session.run(stdout: { output.append(contentsOf: $0) }, stderr: { _ in }, notice: { notices.append($0) })
        #expect(report == ExitReport(status: 0))
        #expect(String(decoding: output, as: UTF8.self) == "out")
        #expect(notices == [GuestNotice(kind: .permissionPrompt, service: "kTCCServiceSystemPolicyDownloadsFolder", program: "/bin/ls", pid: 43)])
    }

    @Test func theExecLogKeepsWhatAProgramWaitedOn() throws {
        let scratch = try Scratch()
        let log = ExecLog(url: scratch.root.appendingPathComponent("exec.jsonl"))
        log.append(ExecLog.Entry(id: "a", event: .start, time: Date(), argv: ["ls", "Downloads"]))
        log.append(ExecLog.Entry(id: "a", event: .end, time: Date(), status: 143, prompts: ["the Downloads folder"]))
        #expect(log.records().first?.prompts == ["the Downloads folder"])
    }
}
