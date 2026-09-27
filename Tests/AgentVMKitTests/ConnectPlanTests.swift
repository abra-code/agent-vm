// Tests/AgentVMKitTests/ConnectPlanTests.swift
//
// What `agent-vm connect` plans for a choice: the steps, the snapshot and report around a
// read-write share, the session child's arguments, how programs are launched through the login
// shell, and the --dry-run lines.

import Foundation
import Testing
@testable import AgentVMKit

@Suite struct ConnectPlanTests {
    let pid: Int32 = 4711

    @Test func aStoppedBoxIsStartedWithoutAnOwner() {
        let steps = ConnectPlanner.steps(for: ConnectRequest(target: .box("b1"), launch: .shell, project: "/p"),
                                         facts: ConnectFacts(boxRunning: false, ownPid: pid))
        #expect(steps.count == 3)
        #expect(steps[0] == .start(box: "b1", ownerPid: nil))
        #expect(steps[1] == .share(box: "b1", project: "/p", readOnly: false))
        guard case .run(let arguments) = steps[2] else {
            Issue.record("the last step is not the run: \(steps)")
            return
        }
        #expect(arguments.starts(with: ["exec", "--tty", "--box", "b1", "--project", "/p", "--"]))
    }

    @Test func aRunningBoxIsNotStarted() {
        let steps = ConnectPlanner.steps(for: ConnectRequest(target: .box("b1"), launch: .shell, project: "/p"),
                                         facts: ConnectFacts(boxRunning: true, ownPid: pid))
        #expect(steps.count == 2)
        #expect(steps[0] == .share(box: "b1", project: "/p", readOnly: false))
    }

    @Test func noProjectMeansNoShare() {
        let steps = ConnectPlanner.steps(for: ConnectRequest(target: .box("b1"), launch: .shell, project: nil),
                                         facts: ConnectFacts(boxRunning: true, ownPid: pid))
        #expect(steps.count == 1)
        guard case .run(let arguments) = steps[0] else {
            Issue.record("not a run: \(steps)")
            return
        }
        #expect(!arguments.contains("--project"))
    }

    @Test func aReadWriteShareIsSnapshotted() {
        let steps = ConnectPlanner.steps(for: ConnectRequest(target: .box("b1"), launch: .shell, project: "/p", snapshot: true),
                                         facts: ConnectFacts(boxRunning: true, ownPid: pid))
        #expect(steps.count == 4)
        #expect(steps[0] == .share(box: "b1", project: "/p", readOnly: false))
        #expect(steps[1] == .snapshot(project: "/p"))
        guard case .run = steps[2] else {
            Issue.record("the third step is not the run: \(steps)")
            return
        }
        #expect(steps[3] == .report(project: "/p"))
    }

    @Test func readOnlyTakesNoSnapshot() {
        let steps = ConnectPlanner.steps(for: ConnectRequest(target: .box("b1"), launch: .shell, project: "/p", readOnly: true, snapshot: true),
                                         facts: ConnectFacts(boxRunning: true, ownPid: pid))
        #expect(steps.count == 2)
        #expect(steps[0] == .share(box: "b1", project: "/p", readOnly: true))
        guard case .run(let arguments) = steps[1] else {
            Issue.record("not a run: \(steps)")
            return
        }
        #expect(arguments.starts(with: ["exec", "--tty", "--box", "b1", "--project", "/p", "--read-only", "--"]))
    }

    @Test func noSnapshotMeansNoReport() {
        let steps = ConnectPlanner.steps(for: ConnectRequest(target: .box("b1"), launch: .shell, project: "/p", snapshot: false),
                                         facts: ConnectFacts(boxRunning: false, ownPid: pid))
        #expect(!steps.contains(.snapshot(project: "/p")))
        #expect(!steps.contains(.report(project: "/p")))
        // No folder, nothing to snapshot.
        let none = ConnectPlanner.steps(for: ConnectRequest(target: .box("b1"), launch: .shell, project: nil, snapshot: true),
                                        facts: ConnectFacts(boxRunning: true, ownPid: pid))
        #expect(none.count == 1)
    }

    @Test func childArgumentsInOrder() {
        let arguments = ConnectPlanner.childArguments(box: "b", project: "/p", readOnly: false, secrets: ["A"], env: ["X=1"],
                                                      argv: ["/bin/echo", "hi"])
        #expect(arguments == ["exec", "--tty", "--box", "b", "--project", "/p", "--secret", "A", "--env", "X=1", "--", "/bin/echo", "hi"])
        let readOnly = ConnectPlanner.childArguments(box: "b", project: "/p", readOnly: true, secrets: [], env: [], argv: ["x"])
        #expect(readOnly == ["exec", "--tty", "--box", "b", "--project", "/p", "--read-only", "--", "x"])
        // The request's specs reach the child as given.
        let steps = ConnectPlanner.steps(for: ConnectRequest(target: .box("b"), launch: .command(["make"]), project: nil,
                                                             secrets: ["TOKEN=NAME", "B"], env: ["Y"]),
                                         facts: ConnectFacts(boxRunning: true, ownPid: pid))
        #expect(steps == [.run(arguments: ["exec", "--tty", "--box", "b", "--secret", "TOKEN=NAME", "--secret", "B", "--env", "Y", "--"]
                                  + ConnectPlanner.loginWrapper + ["make"])])
    }

    @Test func theShellIsBoxShells() {
        // box shell runs exactly this (BoxCommand.Shell).
        #expect(ConnectPlanner.launchArgv(.shell) == ["/bin/sh", "-c", "exec \"$SHELL\" -l"])
    }

    @Test func commandsGoThroughTheLoginShell() throws {
        #expect(ConnectPlanner.launchArgv(.command(["make", "test"])) == ConnectPlanner.loginWrapper + ["make", "test"])
        // On this Mac's shells, the words reach the program untouched.
        let words = ["/usr/bin/printf", "[%s]\\n", "a b", "it's", "$HOME", "\"q\"", ""]
        for shell in ["/bin/zsh", "/bin/bash"] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ConnectPlanner.loginWrapper[0])
            process.arguments = Array(ConnectPlanner.launchArgv(.command(words)).dropFirst())
            process.environment = ["SHELL": shell, "PATH": "/usr/bin:/bin", "HOME": NSTemporaryDirectory()]
            let output = Pipe()
            process.standardOutput = output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
            #expect(String(decoding: data, as: UTF8.self) == "[a b]\n[it's]\n[$HOME]\n[\"q\"]\n[]\n", "\(shell)")
        }
    }

    @Test func dryRunTextsNameEverything() {
        #expect(ConnectStep.start(box: "b1", ownerPid: nil).text == "start box b1")
        #expect(ConnectStep.start(box: "t", ownerPid: 42).text == "start box t, stopping it when process 42 exits")
        #expect(ConnectStep.share(box: "b1", project: "/Users/me/src/app", readOnly: false).text == "share /Users/me/src/app (read-write)")
        #expect(ConnectStep.share(box: "b1", project: "/p", readOnly: true).text == "share /p (read only)")
        #expect(ConnectStep.snapshot(project: "/p").text == "snapshot /p")
        #expect(ConnectStep.report(project: "/p").text == "report what changed in /p, then keep or undo it")
        let run = ConnectStep.run(arguments: ConnectPlanner.childArguments(box: "b1", project: "/my app", readOnly: false, secrets: [],
                                                                          env: [], argv: ConnectPlanner.launchArgv(.command(["claude"]))))
        #expect(run.text == #"run: agent-vm exec --tty --box b1 --project '/my app' -- /bin/sh -c 'exec "$SHELL" -l -c '\''exec "$0" "$@"'\'' "$@"' sh claude"#)
    }
}
