// Sources/AgentVMKit/ProgressEvent.swift
//
// What a long command (image create, update-guest, setup, box start and stop) reports while it
// works. For a person each event is one line of text, exactly as the commands printed before
// events existed; with --json each is one JSON object per line on stderr, so a program can
// show a step and a progress bar without reading prose. Docs/progress-events.md lists the
// steps.

import Foundation

public struct ProgressEvent: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// A step began, or moved on (`fraction`).
        case progress
        /// A line of the log: what happened, or a program's output in the guest (`output`).
        case log
        /// Something the user may need to act on; the command goes on.
        case notice
    }

    public var event: Kind
    /// progress: the step's stable name (Docs/progress-events.md).
    public var step: String?
    /// progress: how far the step is, 0 to 1, when known.
    public var fraction: Double?
    /// progress, recipe steps: this step's number (from 1) and how many there are.
    public var index: Int?
    public var count: Int?
    /// The image or box the event is about.
    public var image: String?
    public var box: String?
    /// log: true for a line a program in the guest printed (a recipe step's output).
    public var output: Bool?
    /// The text, without the indentation the text form adds.
    public var message: String
    /// The line a person sees, indentation included; not part of the JSON.
    public var text: String

    private enum CodingKeys: String, CodingKey {
        case event, step, fraction, index, count, image, box, output, message
    }

    /// `text` is the line as printed; `message` is it without leading spaces.
    public init(_ event: Kind, _ text: String, step: String? = nil, fraction: Double? = nil, index: Int? = nil, count: Int? = nil,
                image: String? = nil, box: String? = nil, output: Bool? = nil) {
        self.event = event
        self.step = step
        self.fraction = fraction
        self.index = index
        self.count = count
        self.image = image
        self.box = box
        self.output = output
        self.text = text
        self.message = String(text.drop(while: { $0 == " " }))
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        event = try container.decode(Kind.self, forKey: .event)
        step = try container.decodeIfPresent(String.self, forKey: .step)
        fraction = try container.decodeIfPresent(Double.self, forKey: .fraction)
        index = try container.decodeIfPresent(Int.self, forKey: .index)
        count = try container.decodeIfPresent(Int.self, forKey: .count)
        image = try container.decodeIfPresent(String.self, forKey: .image)
        box = try container.decodeIfPresent(String.self, forKey: .box)
        output = try container.decodeIfPresent(Bool.self, forKey: .output)
        message = try container.decode(String.self, forKey: .message)
        text = message
    }

    /// The event as one line of JSON (keys sorted), for --json.
    public var jsonLine: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self) else {
            return #"{"event":"log","message":"(unencodable event)"}"#
        }
        return String(decoding: data, as: UTF8.self)
    }
}
