//  Memory.swift — the numbers jetsam reads, and a sampler for the peak.
//
//  `phys_footprint` is what iOS kills an app for exceeding, and on an Apple
//  GPU it includes the engine's Metal buffers (shared memory is the process's
//  memory). `os_proc_available_memory()` is how much more the app may take
//  before that happens, so footprint + available is the app's current limit —
//  the number the increased-memory-limit entitlement is supposed to raise.

import Foundation
import os

enum Memory {
    private static func vmInfo() -> task_vm_info_data_t? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<natural_t>.stride)
        let kr = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? info : nil
    }

    /// Bytes charged to this process: what jetsam compares with the limit.
    static func footprint() -> UInt64 { vmInfo()?.phys_footprint ?? 0 }

    /// The highest footprint since launch, as the kernel's own ledger kept it.
    static func lifetimePeak() -> UInt64 { UInt64(max(0, vmInfo()?.ledger_phys_footprint_peak ?? 0)) }

    /// Bytes this app may still allocate before iOS terminates it.
    static func available() -> UInt64 { UInt64(os_proc_available_memory()) }

    static func mb(_ bytes: UInt64) -> String { String(format: "%.0f MB", Double(bytes) / 1_048_576) }
    static func mb(_ bytes: Double) -> String { String(format: "%.0f MB", bytes / 1_048_576) }
}

/// Samples the footprint on its own thread while a render runs, because the
/// render is one synchronous engine call and its peak happens inside it.
/// `onSample` is called every `persistEvery` samples, so the caller can save
/// the running peak somewhere that survives the app being terminated.
final class PeakSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var peak: UInt64 = 0
    private var minAvailable: UInt64 = .max
    private var running = false
    private let done = DispatchSemaphore(value: 0)

    func start(interval: TimeInterval = 0.005, persistEvery: Int = 40,
               onSample: @escaping @Sendable (_ peak: UInt64, _ minAvailable: UInt64) -> Void) {
        lock.lock()
        peak = Memory.footprint()
        minAvailable = Memory.available()
        running = true
        lock.unlock()
        let thread = Thread { [self] in
            var n = 0
            while true {
                let footprint = Memory.footprint()
                let available = Memory.available()
                lock.lock()
                peak = max(peak, footprint)
                minAvailable = min(minAvailable, available)
                let (p, a, keepGoing) = (peak, minAvailable, running)
                lock.unlock()
                n += 1
                if n % persistEvery == 0 { onSample(p, a) }
                if !keepGoing { break }
                Thread.sleep(forTimeInterval: interval)
            }
            done.signal()
        }
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Stops the thread (after one last sample) and returns what it saw.
    /// Safe to call again: later calls return the same numbers at once.
    func stop() -> (peak: UInt64, minAvailable: UInt64) {
        lock.lock()
        let wasRunning = running
        running = false
        lock.unlock()
        if wasRunning { done.wait() }
        lock.lock()
        defer { lock.unlock() }
        return (peak, minAvailable)
    }
}
