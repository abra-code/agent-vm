// Tests/AgentVMKitTests/GuestClipboardTests.swift
//
// The box window's clipboard buttons (GuestClipboard): which desktop session a Linux box's
// programs name and which tool reaches its clipboard, the requests sent, and what a copy does
// with the guest's answers, through a stand-in for the guest. The tools themselves need a
// desktop in a box and are checked by hand.

import Foundation
import Testing
@testable import AgentVMKit

@Suite struct GuestClipboardSessionTests {
    /// What the probe prints for `processes`, each a list of NAME=value.
    private func probe(_ processes: [[String]]) -> String {
        var output = ""
        for (index, variables) in processes.enumerated() {
            for variable in variables {
                output += "/proc/\(1000 + index)/environ:\(variable)\0"
            }
        }
        return output
    }

    private let xfce = ["DISPLAY=:0", "XAUTHORITY=/home/agent/.Xauthority", "XDG_CURRENT_DESKTOP=XFCE"]
    private let gnome = ["DISPLAY=:0", "XAUTHORITY=/run/user/1000/.mutter-Xwaylandauth.UGE7X3", "WAYLAND_DISPLAY=wayland-0",
                         "XDG_RUNTIME_DIR=/run/user/1000", "XDG_CURRENT_DESKTOP=ubuntu:GNOME"]
    private let kde = ["DISPLAY=:0", "XAUTHORITY=/run/user/1000/xauth_EHwHyy", "WAYLAND_DISPLAY=wayland-0",
                       "XDG_RUNTIME_DIR=/run/user/1000", "XDG_CURRENT_DESKTOP=KDE"]

    @Test func xfceGoesThroughX() throws {
        let session = try #require(GuestClipboard.session(fromProbe: probe([xfce, xfce, []])))
        #expect(!session.usesWayland)
        #expect(session.environment == ["DISPLAY": ":0", "XAUTHORITY": "/home/agent/.Xauthority"])
    }

    @Test func gnomeGoesThroughItsXServer() throws {
        let session = try #require(GuestClipboard.session(fromProbe: probe([gnome])))
        #expect(!session.usesWayland)
        #expect(session.environment == ["DISPLAY": ":0", "XAUTHORITY": "/run/user/1000/.mutter-Xwaylandauth.UGE7X3"])
        // Debian's GNOME names itself without the distribution.
        let debian = gnome.map { $0.hasPrefix("XDG_CURRENT_DESKTOP=") ? "XDG_CURRENT_DESKTOP=GNOME" : $0 }
        #expect(GuestClipboard.session(fromProbe: probe([debian]))?.usesWayland == false)
    }

    @Test func plasmaGoesThroughWayland() throws {
        let session = try #require(GuestClipboard.session(fromProbe: probe([kde])))
        #expect(session.usesWayland)
        #expect(session.environment == ["WAYLAND_DISPLAY": "wayland-0", "XDG_RUNTIME_DIR": "/run/user/1000"])
    }

    @Test func mostProgramsDecide() throws {
        let other = ["DISPLAY=:1", "XAUTHORITY=/tmp/other"]
        let session = try #require(GuestClipboard.session(fromProbe: probe([other, xfce, xfce, other, xfce])))
        #expect(session.display == ":0")
        // As many each: the same answer every time.
        let tie = probe([other, xfce])
        #expect(GuestClipboard.session(fromProbe: tie) == GuestClipboard.session(fromProbe: probe([xfce, other])))
    }

    @Test func noDesktop() {
        #expect(GuestClipboard.session(fromProbe: "") == nil)
        #expect(GuestClipboard.session(fromProbe: probe([["XDG_CURRENT_DESKTOP=XFCE"], ["XAUTHORITY=/home/agent/.Xauthority"]])) == nil)
        // A Wayland socket without its folder is no way in.
        #expect(GuestClipboard.session(fromProbe: probe([["WAYLAND_DISPLAY=wayland-0", "XDG_CURRENT_DESKTOP=KDE"]])) == nil)
    }

    @Test func valuesThatAreNotOnesAreLeftOut() throws {
        // A display over the network, a key file that is no path, a socket name with a folder.
        let odd = ["DISPLAY=example.com:0", "XAUTHORITY=relative", "WAYLAND_DISPLAY=../../tmp/w", "XDG_RUNTIME_DIR=/run/user/1000",
                   "XDG_CURRENT_DESKTOP=KDE"]
        #expect(GuestClipboard.session(fromProbe: probe([odd])) == nil)
        let session = try #require(GuestClipboard.session(fromProbe: probe([["DISPLAY=:0", "XAUTHORITY=x\ny"]])))
        #expect(session.environment == ["DISPLAY": ":0"])
        // Records that are not the probe's are passed over.
        #expect(GuestClipboard.session(fromProbe: "DISPLAY=:0\0/etc/passwd:DISPLAY=:0\0") == nil)
    }

    @Test func localDisplays() {
        for display in [":0", ":1", ":10.0", ":1024"] {
            #expect(GuestClipboard.isLocalDisplay(display), "\(display)")
        }
        for display in ["", ":", "0", ":a", ":0.", ":0.0.0", "host:0", ":12345", ":\u{663}"] {
            #expect(!GuestClipboard.isLocalDisplay(display), "\(display)")
        }
    }

    @Test func probeListsTheDesktopVariables() throws {
        let request = GuestClipboard.sessionProbe(user: "agent")
        #expect(request.user == "agent")
        let script = try #require(request.argv?.last)
        #expect(request.argv?.prefix(2) == ["/bin/sh", "-c"])
        #expect(script == "exec /bin/grep -s -z -H -E '^(DISPLAY|XAUTHORITY|WAYLAND_DISPLAY|XDG_RUNTIME_DIR|XDG_CURRENT_DESKTOP)=' /proc/[0-9]*/environ")
    }

    @Test func requestsPerTool() throws {
        let x = try #require(GuestClipboard.session(fromProbe: probe([xfce])))
        let wayland = try #require(GuestClipboard.session(fromProbe: probe([kde])))
        #expect(GuestClipboard.putRequest(user: "agent", session: x).argv == ["/usr/bin/setsid", "-w", "/usr/bin/xclip", "-selection", "clipboard", "-i"])
        #expect(GuestClipboard.textRequest(user: "agent", session: x).argv == ["/usr/bin/timeout", "10", "/usr/bin/xclip", "-selection", "clipboard", "-o"])
        #expect(GuestClipboard.putRequest(user: "agent", session: wayland).argv
            == ["/usr/bin/setsid", "-w", "/usr/bin/wl-copy", "--type", "text/plain;charset=utf-8"])
        #expect(GuestClipboard.textRequest(user: "agent", session: wayland).argv
            == ["/usr/bin/timeout", "10", "/usr/bin/wl-paste", "--no-newline", "--type", "text"])
        #expect(GuestClipboard.putRequest(user: "agent", session: wayland).env == wayland.environment)
        #expect(GuestClipboard.textRequest(user: "agent", session: x).user == "agent")
    }

    @Test func emptyClipboards() {
        #expect(GuestClipboard.isEmptyClipboard((ExitReport(status: 1), "", "Error: target STRING not available\n")))
        #expect(GuestClipboard.isEmptyClipboard((ExitReport(status: 1), "", "Nothing is copied\n")))
        #expect(GuestClipboard.isEmptyClipboard((ExitReport(status: 1), "", "No suitable type of content copied\n")))
        #expect(!GuestClipboard.isEmptyClipboard((ExitReport(status: 1), "", "Error: Can't open display: :0\n")))
        #expect(!GuestClipboard.isEmptyClipboard((ExitReport(status: 0), "", "")))
    }

    @Test func characterCounts() {
        #expect(BoxViewer.characters("a") == "1 character")
        #expect(BoxViewer.characters("e\u{301}x") == "2 characters")
    }
}

/// A copy end to end against a stand-in for the guest: it answers each request from `answer`
/// and keeps the requests and their stdin.
@MainActor
@Suite struct GuestClipboardCopyTests {
    @MainActor
    private final class Guest {
        var requests: [(GuestRequest, Data?)] = []
        var answer: (GuestRequest) throws -> GuestClipboard.Captured

        init(_ answer: @escaping (GuestRequest) throws -> GuestClipboard.Captured) {
            self.answer = answer
        }

        func clipboard(_ kind: GuestKind) -> GuestClipboard {
            return GuestClipboard(guest: kind, user: "agent") { request, input in
                self.requests.append((request, input))
                return try self.answer(request)
            }
        }
    }

    private static let ok = ExitReport(status: 0)
    private static let xfceProbe = "/proc/900/environ:DISPLAY=:0\0/proc/900/environ:XAUTHORITY=/home/agent/.Xauthority\0"

    @Test func macOSUsesPbcopyAndPbpaste() async throws {
        let guest = Guest { request in
            request.argv == ["/usr/bin/pbpaste"] ? (Self.ok, "copied\r\nin \u{1B}[31mthe box\u{200B}", "") : (Self.ok, "", "")
        }
        try await guest.clipboard(.macOS).put("from the Mac \u{E9}")
        #expect(guest.requests.first?.0.argv == ["/usr/bin/pbcopy"])
        #expect(guest.requests.first?.0.user == "agent")
        #expect(guest.requests.first?.1 == Data("from the Mac \u{E9}".utf8))
        // Made harmless to paste: line ends as "\n", no escape, no zero-width space.
        #expect(try await guest.clipboard(.macOS).text() == "copied\nin [31mthe box")
    }

    @Test func linuxFindsTheDesktopFirst() async throws {
        let guest = Guest { request in
            switch request.argv?.first {
            case "/bin/sh":
                return (Self.ok, Self.xfceProbe, "")
            case "/usr/bin/timeout":
                return (Self.ok, "text in X", "")
            default:
                return (Self.ok, "", "")
            }
        }
        try await guest.clipboard(.linux).put("hello")
        #expect(guest.requests.map { $0.0.argv?.first } == ["/bin/sh", "/usr/bin/setsid"])
        #expect(guest.requests.last?.0.env == ["DISPLAY": ":0", "XAUTHORITY": "/home/agent/.Xauthority"])
        #expect(guest.requests.last?.1 == Data("hello".utf8))
        #expect(try await guest.clipboard(.linux).text() == "text in X")
    }

    @Test func emptyIsNoText() async throws {
        let linux = Guest { request in
            request.argv?.first == "/bin/sh" ? (Self.ok, Self.xfceProbe, "") : (ExitReport(status: 1), "", "Error: target STRING not available\n")
        }
        #expect(try await linux.clipboard(.linux).text() == "")
        let mac = Guest { _ in (Self.ok, "", "") }
        #expect(try await mac.clipboard(.macOS).text() == "")
    }

    @Test func failuresSayWhy() async throws {
        let noDesktop = Guest { _ in (ExitReport(status: 1), "", "") }
        await #expect(throws: GuestClipboard.Failure(description: "found no desktop in the box: none of agent's programs names an X or Wayland display")) {
            try await noDesktop.clipboard(.linux).put("x")
        }
        let noTool = Guest { request in
            request.argv?.first == "/bin/sh" ? (Self.ok, Self.xfceProbe, "") : (ExitReport(status: 127), "", "")
        }
        let missing = await #expect(throws: GuestClipboard.Failure.self) {
            try await noTool.clipboard(.linux).text()
        }
        #expect(missing?.description.contains("the box has no xclip") == true)
        let hung = Guest { request in
            request.argv?.first == "/bin/sh" ? (Self.ok, Self.xfceProbe, "") : (ExitReport(status: 124), "", "")
        }
        let late = await #expect(throws: GuestClipboard.Failure.self) {
            try await hung.clipboard(.linux).text()
        }
        #expect(late?.description.contains("did not answer within 10 seconds") == true)
        let refused = Guest { _ in (ExitReport(status: 1), "", "pbcopy: refused\n") }
        let other = await #expect(throws: GuestClipboard.Failure.self) {
            try await refused.clipboard(.macOS).put("x")
        }
        #expect(other?.description == "could not put the text on the clipboard in the box (status 1): pbcopy: refused")
        // A read that failed part way says why, never the text it printed.
        let partial = Guest { _ in (ExitReport(status: 2), "secret text", "") }
        let failed = await #expect(throws: GuestClipboard.Failure.self) {
            try await partial.clipboard(.macOS).text()
        }
        #expect(failed?.description == "could not read the clipboard in the box (status 2)")
    }

    @Test func tooMuchText() async throws {
        let guest = Guest { _ in throw GuestProtocolError.malformed("the program printed more than 1048576 bytes") }
        await #expect(throws: GuestClipboard.Failure(description: "the clipboard in the box holds over 1 MB of text")) {
            try await guest.clipboard(.macOS).text()
        }
        await #expect(throws: GuestClipboard.Failure(description: "the text on this Mac's clipboard is over 1 MB")) {
            try await guest.clipboard(.macOS).put(String(repeating: "x", count: GuestClipboard.maximumBytes + 1))
        }
        #expect(guest.requests.count == 1)
    }
}
