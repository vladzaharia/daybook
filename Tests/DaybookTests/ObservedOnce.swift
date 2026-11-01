import DaybookDevices
import Foundation

/// Whether `condition` held at some point, checked now and after each change to what it reads (`ObservationWatch`):
/// "a countdown never appeared", for the app's `@Observable` models.
@MainActor
final class ObservedOnce {
    private(set) var happened = false
    private var watch: ObservationWatch?

    init(_ condition: @escaping @MainActor () -> Bool) {
        watch = ObservationWatch.values(of: condition) { [weak self] holds in
            if holds { self?.happened = true }
        }
    }

    func cancel() { watch?.cancel() }
}
