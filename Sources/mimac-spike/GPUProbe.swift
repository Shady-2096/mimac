import Foundation
import IOKit

// MARK: - System-wide GPU utilization (Appendix A item 12) + per-process GPU note (item 13)

enum GPUProbe {

    /// Returns PerformanceStatistics dictionaries for every IOAccelerator instance.
    static func performanceStatistics() -> [[String: Any]] {
        var results: [[String: Any]] = []
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iter) == KERN_SUCCESS else {
            return results
        }
        defer { IOObjectRelease(iter) }
        var entry = IOIteratorNext(iter)
        while entry != 0 {
            defer { IOObjectRelease(entry); entry = IOIteratorNext(iter) }
            var propsRef: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(entry, &propsRef, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let props = propsRef?.takeRetainedValue() as? [String: Any] else { continue }
            if let stats = props["PerformanceStatistics"] as? [String: Any] {
                results.append(stats)
            }
        }
        return results
    }

    static func deviceUtilization() -> Double? {
        for stats in performanceStatistics() {
            if let value = utilization(in: stats) { return value }
        }
        return nil
    }

    private static func utilization(in stats: [String: Any]) -> Double? {
        for key in ["Device Utilization %", "GPU Activity(%)", "Device Utilization"] {
            if let value = (stats[key] as? NSNumber)?.doubleValue { return value }
        }
        return nil
    }

    static func probe() -> (ProbeResult, ProbeResult) {
        var evidence: [String] = []
        let all = performanceStatistics()
        var verdict: Verdict = .unavailable
        var detail = "no IOAccelerator PerformanceStatistics found"

        if let stats = all.first {
            let interesting = stats.keys.sorted().filter {
                $0.localizedCaseInsensitiveContains("utilization") ||
                $0.localizedCaseInsensitiveContains("activity") ||
                $0.localizedCaseInsensitiveContains("in use") ||
                $0.localizedCaseInsensitiveContains("power")
            }
            evidence.append("IOAccelerator instances: \(all.count); PerformanceStatistics keys: \(stats.count)")
            for k in interesting {
                evidence.append("  \(k) = \(stats[k] ?? "?")")
            }
            if let util = utilization(in: stats) {
                verdict = .measured
                detail = String(format: "system-wide GPU utilization readable (%.0f%% now)", util)
            } else {
                verdict = .estimable
                detail = "PerformanceStatistics present but no recognized utilization key; keys logged"
                evidence.append("All keys: \(stats.keys.sorted().joined(separator: ", "))")
            }
        }

        let sysGPU = ProbeResult(id: 12, metric: "System-wide GPU utilization", api: "IOAccelerator PerformanceStatistics (IORegistry)",
                                 verdict: verdict, detail: detail, evidence: evidence)
        let perProc = ProbeResult(id: 13, metric: "Per-process GPU", api: "— (no public API)",
                                  verdict: .unavailable,
                                  detail: "no public API, as expected; estimate-only via heuristics (confirmed by design, not probed)",
                                  evidence: ["Per-process GPU attribution has no public API on macOS. The app must show system-wide GPU (item 12) and label any per-process split as an estimate."])
        return (sysGPU, perProc)
    }
}
