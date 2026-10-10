// Sources/AgentVMKit/ProgressPacer.swift
//
// When a step that is usually over at once says how far it is: not at all while it is quick,
// once after a few seconds, and then at a steady interval. The step asks as often as it
// likes; asking costs one reading of the clock.

public struct ProgressPacer {
    private let clock = ContinuousClock()
    private let interval: Duration
    private var next: ContinuousClock.Instant

    /// The first line is due `first` from now, each later one `interval` after the last.
    public init(first: Duration = .seconds(3), interval: Duration = .seconds(10)) {
        self.interval = interval
        next = clock.now + first
    }

    /// True when a line is due; the next one is then due an interval from now.
    public mutating func isDue() -> Bool {
        let now = clock.now
        guard now >= next else {
            return false
        }
        next = now + interval
        return true
    }
}
