import Darwin
import Foundation
import os

/// How much memory iOS lets Daybook use (docs/models.md, "iPhone processing"): what a summary model's
/// peak has to fit in. iOS ends an app that goes past its limit, which depends on the iPhone and on the
/// Increased Memory Limit entitlement, so it's read as the app runs rather than assumed.
enum PhoneMemory {
    /// The limit now: what's left before it (`os_proc_available_memory`) plus what Daybook already uses.
    /// Nil where iOS doesn't say (the simulator); `AppMemoryLimit.estimate` stands in then.
    static func limit() -> UInt64? {
        #if targetEnvironment(simulator)
        return nil
        #else
        let available = os_proc_available_memory()
        guard available > 0 else { return nil }
        return UInt64(available) + footprint()
        #endif
    }

    /// What Daybook uses now, as iOS counts it against the limit.
    static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
    }

    /// Language models run on the graphics processor through MLX, which the simulator's can't serve.
    static var runsLanguageModels: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return true
        #endif
    }
}
