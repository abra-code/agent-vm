// Tests/AgentVMKitTests/ProgressEventTests.swift
//
// Progress events: the text a person sees is kept exactly, and --json gets one object per
// line without the indentation or the text-only field.

import Foundation
import Testing
@testable import AgentVMKit

@Suite struct ProgressEventTests {
    @Test func textIsKeptAndTheMessageLosesItsIndentation() {
        let event = ProgressEvent(.progress, "  40%", step: "install", fraction: 0.4, image: "dev")
        #expect(event.text == "  40%")
        #expect(event.message == "40%")
        #expect(event.jsonLine == #"{"event":"progress","fraction":0.4,"image":"dev","message":"40%","step":"install"}"#)
    }

    @Test func oneLineWithOnlyWhatIsKnown() {
        let event = ProgressEvent(.log, "path /a/b\nsecond", image: nil)
        #expect(event.jsonLine == #"{"event":"log","message":"path /a/b\nsecond"}"#)
        #expect(!event.jsonLine.contains("\n"))
    }

    @Test func recipeStepsCarryTheirNumber() throws {
        let event = ProgressEvent(.progress, "  [2/4] Node", step: "recipe-step", fraction: 0.25, index: 2, count: 4, image: "dev-node")
        let decoded = try JSONDecoder().decode(ProgressEvent.self, from: Data(event.jsonLine.utf8))
        #expect(decoded.step == "recipe-step")
        #expect(decoded.index == 2 && decoded.count == 4)
        #expect(decoded.message == "[2/4] Node")
    }

    /// A recipe step's output: indented and marked for a person, plain with output: true in JSON.
    @MainActor
    @Test func guestOutputLinesAreMarked() async throws {
        let collected = Collected()
        let emitter = LineEmitter(report: { collected.events.append($0) }, image: "dev")
        emitter.add(Array("hello\nwor".utf8))
        emitter.add(Array("ld\n".utf8))
        // Lines are delivered on the main queue.
        for _ in 0..<50 where collected.events.count < 2 {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(collected.events.map(\.text) == ["      | hello", "      | world"])
        #expect(collected.events.map(\.message) == ["hello", "world"])
        #expect(collected.events.allSatisfy { $0.output == true && $0.event == .log && $0.image == "dev" })
    }
}

@MainActor
private final class Collected {
    var events: [ProgressEvent] = []
}
