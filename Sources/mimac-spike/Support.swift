import Foundation
import CShim

// MARK: - Mach time

enum MachTime {
    static let timebase: mach_timebase_info_data_t = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return tb
    }()

    /// Convert mach ticks to seconds.
    static func seconds(_ ticks: UInt64) -> Double {
        Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1e9
    }
}

// MARK: - Probe result model

enum Verdict: String {
    case measured = "Measured"
    case estimable = "Estimable"
    case unavailable = "Unavailable"
}

struct ProbeResult {
    let id: Int              // Appendix A row number
    let metric: String
    let api: String
    var verdict: Verdict
    var detail: String       // one-line summary of what was observed
    var evidence: [String]   // raw sample lines for the report
}

// MARK: - Formatting

func fmtBytes(_ b: UInt64) -> String {
    let d = Double(b)
    switch d {
    case ..<1024: return String(format: "%.0f B", d)
    case ..<1_048_576: return String(format: "%.1f KB", d / 1024)
    case ..<1_073_741_824: return String(format: "%.1f MB", d / 1_048_576)
    default: return String(format: "%.2f GB", d / 1_073_741_824)
    }
}

func fmtJ(_ nj: UInt64) -> String {
    let j = Double(nj) / 1e9
    if j < 1 { return String(format: "%.3f J", j) }
    if j < 3600 { return String(format: "%.1f J", j) }
    return String(format: "%.3f Wh", j / 3600)
}

func pad(_ s: String, _ w: Int, right: Bool = false) -> String {
    if s.count >= w { return String(s.prefix(w)) }
    let fill = String(repeating: " ", count: w - s.count)
    return right ? fill + s : s + fill
}

// MARK: - Machine info

struct MachineInfo {
    static func summary() -> [String] {
        var lines: [String] = []
        var size = 256
        var buf = [CChar](repeating: 0, count: size)
        if sysctlbyname("hw.model", &buf, &size, nil, 0) == 0 {
            lines.append("Model: \(String(cString: buf))")
        }
        size = 256; buf = [CChar](repeating: 0, count: size)
        if sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0) == 0 {
            lines.append("Chip: \(String(cString: buf))")
        }
        var ncpu: Int32 = 0; var len = MemoryLayout<Int32>.size
        sysctlbyname("hw.ncpu", &ncpu, &len, nil, 0)
        var perf0: Int32 = 0; len = MemoryLayout<Int32>.size
        let hasPerf0 = sysctlbyname("hw.perflevel0.logicalcpu", &perf0, &len, nil, 0) == 0
        var perf1: Int32 = 0; len = MemoryLayout<Int32>.size
        let hasPerf1 = sysctlbyname("hw.perflevel1.logicalcpu", &perf1, &len, nil, 0) == 0
        if hasPerf0 && hasPerf1 {
            lines.append("Cores: \(ncpu) total (\(perf0) P + \(perf1) E)")
        } else {
            lines.append("Cores: \(ncpu)")
        }
        let osv = ProcessInfo.processInfo.operatingSystemVersion
        lines.append("macOS: \(osv.majorVersion).\(osv.minorVersion).\(osv.patchVersion)")
        lines.append("Run as: uid=\(getuid()) euid=\(geteuid())\(geteuid() == 0 ? " (privileged)" : " (plain user)")")
        return lines
    }
}
