import Foundation
import Observation

/// The last few seconds of input level, for the recording screen's rolling meter. Fed about fifteen
/// times a second from the recorder's level callback; views draw it with a Canvas.
@MainActor
@Observable
final class LevelHistory {
    /// Oldest first, 0...1.
    private(set) var values: [Double]
    let capacity: Int

    init(capacity: Int = 96) {
        self.capacity = capacity
        values = Array(repeating: 0, count: capacity)
    }

    func append(_ value: Double) {
        var next = values
        next.removeFirst(max(0, next.count - capacity + 1))
        next.append(max(0, min(1, value)))
        values = next
    }

    /// A pause or a new recording: the meter falls flat.
    func reset() {
        values = Array(repeating: 0, count: capacity)
    }
}
