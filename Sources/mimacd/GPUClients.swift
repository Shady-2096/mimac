import Foundation
import IOKit

/// Per-process GPU time, read without privileges from the Apple GPU driver.
///
/// Every Metal client opens an `AGXDeviceUserClient`. Its IORegistry entry names
/// the owner (`IOUserClientCreator` = "pid 422, WindowServer") and carries an
/// `AppUsage` array whose `accumulatedGPUTime` counts nanoseconds of GPU work.
/// This is the source of Activity Monitor's "% GPU" and "GPU Time" columns, and
/// it covers root-owned processes such as WindowServer that `proc_pid_rusage`
/// refuses. A process with several clients (one per Metal device/queue) has
/// them summed.
final class GPUClientSampler {
    private var previous: [Int32: UInt64] = [:]

    /// GPU busy share per pid since the previous call, in percent of one GPU,
    /// or nil when the driver publishes no clients (not Apple Silicon).
    /// The first call establishes the baseline and returns zeros.
    func sample(intervalSeconds: Double) -> [Int32: Double]? {
        guard let totals = Self.readTotals() else { return nil }
        defer { previous = totals }
        var result: [Int32: Double] = [:]
        let interval = max(0.001, intervalSeconds)
        for (pid, nanoseconds) in totals {
            // A client that closed takes its time with it, so a pid's total can
            // drop; skip that interval rather than report a negative share.
            guard let old = previous[pid], nanoseconds > old else { continue }
            result[pid] = Double(nanoseconds - old) / 1e9 / interval * 100
        }
        return result
    }

    /// User clients are not registered services, so `IOServiceGetMatchingServices`
    /// never returns them; they hang off the accelerator as children in the
    /// service plane, which is where `ioreg -c` finds them.
    private static func readTotals() -> [Int32: UInt64]? {
        var accelerators: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IOAccelerator"),
            &accelerators
        ) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(accelerators) }

        var totals: [Int32: UInt64] = [:]
        var sawClient = false
        var accelerator = IOIteratorNext(accelerators)
        while accelerator != 0 {
            defer {
                IOObjectRelease(accelerator)
                accelerator = IOIteratorNext(accelerators)
            }
            var children: io_iterator_t = 0
            guard IORegistryEntryGetChildIterator(accelerator, kIOServicePlane, &children) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(children) }
            var entry = IOIteratorNext(children)
            while entry != 0 {
                defer {
                    IOObjectRelease(entry)
                    entry = IOIteratorNext(children)
                }
                guard let creator = property(entry, "IOUserClientCreator") as? String,
                      let pid = pid(fromCreator: creator) else { continue }
                sawClient = true
                guard let usage = property(entry, "AppUsage") as? [[String: Any]] else { continue }
                let nanoseconds = usage.reduce(UInt64(0)) { sum, item in
                    sum &+ ((item["accumulatedGPUTime"] as? NSNumber)?.uint64Value ?? 0)
                }
                totals[pid, default: 0] &+= nanoseconds
            }
        }
        return sawClient ? totals : nil
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    /// "pid 422, WindowServer" → 422.
    static func pid(fromCreator creator: String) -> Int32? {
        guard creator.hasPrefix("pid ") else { return nil }
        let digits = creator.dropFirst(4).prefix { $0.isNumber }
        return Int32(digits)
    }
}
