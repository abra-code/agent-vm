// Tests/AgentVMKitTests/RecipeInputTests.swift
//
// Recipe inputs (files given with --input and streamed into the guest) and parameters (values
// given with --set): declarations, the checks when values are bound, the variables steps and
// checks see, and the script that writes an input in the guest.

import Foundation
import Testing
@testable import AgentVMKit

@Suite struct RecipeInputTests {
    private func load(_ json: String, in scratch: Scratch) throws -> ImageRecipe {
        let url = scratch.root.appendingPathComponent("recipe.json")
        try Data(json.utf8).write(to: url)
        return try ImageRecipe.load(from: url)
    }

    private func reason(_ body: () throws -> Any) -> String? {
        do {
            _ = try body()
            return nil
        } catch let AgentVMError.invalidRecipe(_, reason) {
            return reason
        } catch {
            return "\(error)"
        }
    }

    private let xcodeRecipe = """
        {
          "version": 1,
          "inputs": {"xcode": {"description": "an Xcode .xip"}},
          "parameters": {
            "platforms": {"description": "runtimes", "default": "iOS"},
            "team": {"description": "who"}
          },
          "steps": [{"run": "echo \\"$AGENT_VM_INPUT_XCODE\\"", "env": {"AGENT_VM_PARAM_TEAM": "from the step"}}]
        }
        """

    @Test func declarationsParse() throws {
        let scratch = try Scratch()
        let recipe = try load(xcodeRecipe, in: scratch)
        #expect(recipe.inputs == [ImageRecipe.Input(name: "xcode", description: "an Xcode .xip")])
        #expect(recipe.parameters == [ImageRecipe.Parameter(name: "platforms", description: "runtimes", defaultValue: "iOS"),
                                      ImageRecipe.Parameter(name: "team", description: "who", defaultValue: nil)])
        #expect(recipe.path.hasSuffix("recipe.json"))
    }

    @Test func badDeclarationsAreRefused() throws {
        let scratch = try Scratch()
        let cases: [(String, String)] = [
            (#"{"version": 1, "inputs": {"Xcode": {}}}"#, "not a usable name"),
            (#"{"version": 1, "inputs": {"1x": {}}}"#, "not a usable name"),
            (#"{"version": 1, "inputs": ["xcode"]}"#, "must be a JSON object of names"),
            (#"{"version": 1, "inputs": {"xcode": "file"}}"#, "must be a JSON object"),
            (#"{"version": 1, "inputs": {"xcode": {"path": "x"}}}"#, "unknown key \"path\""),
            (#"{"version": 1, "parameters": {"p": {"default": 3}}}"#, "\"default\" must be a string"),
            (#"{"version": 1, "inputs": {"x": {}}, "parameters": {"x": {}}}"#, "both an input and a parameter"),
        ]
        for (json, expected) in cases {
            let message = reason { try load(json, in: scratch) }
            #expect(message?.contains(expected) == true, "\(json): \(message ?? "accepted")")
        }
    }

    @Test func bindingChecksEveryValue() throws {
        let scratch = try Scratch()
        let recipe = try load(xcodeRecipe, in: scratch)
        let xip = scratch.root.appendingPathComponent("Xcode_27.xip")
        try Data("xip".utf8).write(to: xip)

        #expect(reason { try recipe.binding(inputs: [:], parameters: ["team": "a"]) }?.contains("needs --input xcode=PATH: an Xcode .xip") == true)
        #expect(reason { try recipe.binding(inputs: ["xcode": xip.path, "other": "/x"], parameters: ["team": "a"]) }?.contains("has no input other (its inputs: xcode)") == true)
        #expect(reason { try recipe.binding(inputs: ["xcode": xip.path + ".missing"], parameters: ["team": "a"]) }?.contains("does not exist") == true)
        #expect(reason { try recipe.binding(inputs: ["xcode": scratch.root.path], parameters: ["team": "a"]) }?.contains("is not a readable file") == true)
        #expect(reason { try recipe.binding(inputs: ["xcode": xip.path], parameters: [:]) }?.contains("needs --set team=VALUE: who") == true)
        #expect(reason { try recipe.binding(inputs: ["xcode": xip.path], parameters: ["team": "a", "size": "1"]) }?.contains("has no parameter size (its parameters: platforms, team)") == true)

        let bound = try recipe.binding(inputs: ["xcode": xip.path], parameters: ["team": "a b"])
        #expect(bound.inputFiles["xcode"]?.lastPathComponent == "Xcode_27.xip")
        #expect(bound.parameterValues == ["platforms": "iOS", "team": "a b"])
        let overridden = try recipe.binding(inputs: ["xcode": xip.path], parameters: ["team": "", "platforms": "iOS watchOS"])
        #expect(overridden.parameterValues == ["platforms": "iOS watchOS", "team": ""])
    }

    /// Steps and checks see the parameters and the inputs' paths in the guest; a step's own
    /// `env` cannot override them.
    @Test func stepsAndChecksSeeTheValues() throws {
        let scratch = try Scratch()
        let xip = scratch.root.appendingPathComponent("Xcode_27.xip")
        try Data("xip".utf8).write(to: xip)
        let recipe = try load(xcodeRecipe, in: scratch).binding(inputs: ["xcode": xip.path], parameters: ["team": "a"])
        let expected = [
            "AGENT_VM_INPUT_XCODE": "/private/var/tmp/agent-vm-inputs/xcode/Xcode_27.xip",
            "AGENT_VM_PARAM_PLATFORMS": "iOS",
            "AGENT_VM_PARAM_TEAM": "a",
        ]
        #expect(recipe.variables == expected)
        let run = ImageRecipe.runRequest(recipe.steps[0], command: "true", boxUser: "agent", variables: recipe.variables)
        #expect(run.env == expected.merging(["AGENT_VM_BOX_USER": "agent"]) { $1 })
        #expect(ImageRecipe.checkRequest("true", variables: recipe.variables).env == expected)
        #expect(ImageRecipe.checkRequest("true").env == nil)
    }

    /// The input script, run here with bash: the folder is created, stdin becomes the file,
    /// and both are readable by every account.
    @Test func theInputScriptWritesTheFile() throws {
        let scratch = try Scratch()
        let target = scratch.root.appendingPathComponent("inputs/xcode/Xcode.xip").path
        let request = ImageRecipe.inputRequest(path: target)
        #expect(request.user == "root")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: request.argv![0])
        process.arguments = Array(request.argv!.dropFirst())
        let input = Pipe()
        process.standardInput = input
        try process.run()
        input.fileHandleForWriting.write(Data("contents".utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(try String(contentsOfFile: target, encoding: .utf8) == "contents")
        let file = try FileManager.default.attributesOfItem(atPath: target)[.posixPermissions] as? Int
        let folder = try FileManager.default.attributesOfItem(atPath: (target as NSString).deletingLastPathComponent)[.posixPermissions] as? Int
        #expect(file == 0o644 && folder == 0o755)
    }
}

/// Input sent before anything is read, against a fake guest that ends first: the program's own
/// report is what the caller gets, never "write failed: Broken pipe".
@Suite struct InputDeliveryTests {
    /// A fake guest on one end of a socket pair. `act` gets its channel after the request was
    /// read and the exec answered; the guest's end is closed when `act` returns. `finish` waits
    /// for the guest before closing the other end, so no thread uses a closed descriptor.
    final class FakeGuest {
        let host: Int32
        private let done = DispatchSemaphore(value: 0)

        init(_ act: @escaping @Sendable (FrameChannel) -> Void) throws {
            var pair: [Int32] = [-1, -1]
            guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else {
                throw AgentVMError.system(operation: "socketpair", code: errno)
            }
            host = pair[0]
            let guest = FrameChannel(descriptor: pair[1])
            let done = self.done
            Thread.detachNewThread {
                defer { done.signal() }
                _ = try? guest.receive()
                try? guest.send(.response, json: GuestResponse(ok: true, v: AgentVM.guestProtocolVersion, pid: 42))
                act(guest)
                guest.close()
            }
        }

        func finish() {
            // Ends a guest still waiting for input (a test that failed before sending it all).
            shutdown(host, SHUT_RDWR)
            done.wait()
            close(host)
        }
    }

    /// Reads input frames until `count` bytes arrived or stdin ended.
    static func take(_ guest: FrameChannel, _ count: Int) -> Int {
        var got = 0
        while got < count, let frame = try? guest.receive(), frame.type == .stdin {
            got += frame.payload.count
        }
        return got
    }

    func bigFile(_ scratch: Scratch) throws -> URL {
        let url = scratch.root.appendingPathComponent("input.bin")
        // Far more than the socket buffers hold, so sending is still under way at the close.
        try Data(repeating: 7, count: 12 << 20).write(to: url)
        return url
    }

    @Test func sendInputReportsAGuestThatClosed() throws {
        let fake = try FakeGuest { guest in
            try? guest.send(.exit, json: ExitReport(status: 3))
        }
        defer { fake.finish() }
        let session = try ExecSession(descriptor: fake.host, request: GuestRequest(op: .exec, argv: ["/bin/true"]))
        #expect(try session.sendInput([UInt8](repeating: 0, count: 8 << 20)) == false)
        #expect(try session.endInput() == false)
        #expect(try session.run(stdout: { _ in }, stderr: { _ in }) == ExitReport(status: 3))
    }

    @Test func aGuestFailingPartwayGivesItsOwnError() throws {
        let scratch = try Scratch()
        let fake = try FakeGuest { guest in
            _ = Self.take(guest, 1 << 20)
            try? guest.send(Frame(.stderr, Array("cat: No space left on device\n".utf8)))
            try? guest.send(.exit, json: ExitReport(status: 1))
        }
        defer { fake.finish() }
        do {
            _ = try ImageBuilder.streamInput(try bigFile(scratch), name: "xip", to: "/tmp/x", descriptor: fake.host)
            Issue.record("the send succeeded")
        } catch let AgentVMError.guestCommandFailed(command, status, output) {
            #expect(command == "send input xip")
            #expect(status == 1)
            #expect(output == "cat: No space left on device")
        }
    }

    @Test func aGuestStoppingEarlyWithSuccessIsNotTakenAsComplete() throws {
        let scratch = try Scratch()
        let fake = try FakeGuest { guest in
            _ = Self.take(guest, 1 << 20)
            try? guest.send(.exit, json: ExitReport(status: 0))
        }
        defer { fake.finish() }
        do {
            _ = try ImageBuilder.streamInput(try bigFile(scratch), name: "xip", to: "/tmp/x", descriptor: fake.host)
            Issue.record("the send succeeded")
        } catch let AgentVMError.guestRefused(reason) {
            #expect(reason.hasPrefix("input xip: it stopped taking the file after "), "\(reason)")
            #expect(reason.contains("of \(12 << 20) bytes, yet reported success"), "\(reason)")
        }
    }

    @Test func aCompleteSendIsRecorded() throws {
        let scratch = try Scratch()
        let file = try bigFile(scratch)
        let fake = try FakeGuest { guest in
            _ = Self.take(guest, Int.max)
            try? guest.send(.exit, json: ExitReport(status: 0))
        }
        defer { fake.finish() }
        let info = try ImageBuilder.streamInput(file, name: "xip", to: "/tmp/x", descriptor: fake.host)
        #expect(info.bytes == Int64(12 << 20))
        #expect(info.sha256.count == 64)
    }
}
