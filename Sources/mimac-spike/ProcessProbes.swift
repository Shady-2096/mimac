import Foundation
import CShim
import MimacCore

// MARK: - Energy census (Appendix A item 7 & 8 — the load-bearing unknown)

struct EnergyCensus {
    var total: Int = 0
    var rusageOK: Int = 0
    var flavor6: Int = 0
    var billedEnergyNonzero: Int = 0
    var energyNJNonzero: Int = 0
    var penergyNonzero: Int = 0
    var ptimeNonzero: Int = 0
    var qosNonzero: Int = 0
    var deniedPids: Int = 0
    var topByEnergy: [(String, Int32, UInt64, UInt64)] = []

    static func run() -> EnergyCensus {
        var c = EnergyCensus()
        var rows: [(String, Int32, UInt64, UInt64)] = []
        for pid in ProcAPI.allPids() {
            c.total += 1
            guard let ru = ProcAPI.rusage(for: pid) else { c.deniedPids += 1; continue }
            c.rusageOK += 1
            if ru.flavor == 6 { c.flavor6 += 1 }
            if ru.billed_energy > 0 { c.billedEnergyNonzero += 1 }
            if ru.energy_nj > 0 { c.energyNJNonzero += 1 }
            if ru.penergy_nj > 0 { c.penergyNonzero += 1 }
            if ru.user_ptime_mach + ru.system_ptime_mach > 0 { c.ptimeNonzero += 1 }
            let qos = ru.qos_default + ru.qos_background + ru.qos_utility + ru.qos_legacy
                    + ru.qos_user_initiated + ru.qos_user_interactive + ru.qos_maintenance
            if qos > 0 { c.qosNonzero += 1 }
            let e = max(ru.energy_nj, ru.billed_energy)
            if e > 0 { rows.append((ProcAPI.name(for: pid), pid, ru.energy_nj, ru.billed_energy)) }
        }
        c.topByEnergy = rows.sorted { max($0.2, $0.3) > max($1.2, $1.3) }.prefix(10).map { $0 }
        return c
    }
}

// MARK: - Coalition probe (Appendix A item 9)

struct CoalitionProbe {
    static func run() -> ProbeResult {
        var evidence: [String] = []
        var ids = [UInt64](repeating: 0, count: 2)
        let selfRC = cshim_pid_coalition_ids(getpid(), &ids)
        if selfRC == 0 {
            evidence.append("PROC_PIDCOALITIONINFO(self): resource coalition id = \(ids[0]), jetsam id = \(ids[1])")
        } else {
            evidence.append("PROC_PIDCOALITIONINFO(self) failed rc=\(selfRC)")
        }

        var usage = cshim_coalition_usage()
        let rc = cshim_coalition_resource_usage(ids[0], &usage)
        if rc == 0 {
            evidence.append("coalition_info_resource_usage(cid \(ids[0])): cpu_time=\(String(format: "%.2f", MachTime.seconds(usage.cpu_time)))s energy=\(fmtJ(usage.energy)) tasks=\(usage.tasks_started) gpu_time=\(usage.gpu_time)")
            evidence.append("  energy_billed_to_me=\(fmtJ(usage.energy_billed_to_me)) cpu_ptime=\(String(format: "%.2f", MachTime.seconds(usage.cpu_ptime)))s")
            var seen = Set<UInt64>()
            var sampled = 0
            for pid in ProcAPI.allPids().shuffled() where sampled < 5 {
                var cids = [UInt64](repeating: 0, count: 2)
                guard cshim_pid_coalition_ids(pid, &cids) == 0, cids[0] != 0, !seen.contains(cids[0]) else { continue }
                seen.insert(cids[0])
                var u = cshim_coalition_usage()
                if cshim_coalition_resource_usage(cids[0], &u) == 0 {
                    evidence.append("cid \(cids[0]) (\(ProcAPI.name(for: pid))): cpu=\(String(format: "%.1f", MachTime.seconds(u.cpu_time)))s energy=\(fmtJ(u.energy))")
                    sampled += 1
                } else {
                    evidence.append("cid \(cids[0]) (\(ProcAPI.name(for: pid))): usage read FAILED")
                }
            }
            return ProbeResult(id: 9, metric: "Coalition membership & per-coalition usage", api: "coalition_info (private syscall) + PROC_PIDCOALITIONINFO", verdict: .measured, detail: "coalition ids readable; coalition_info_resource_usage returns cpu/energy per coalition", evidence: evidence)
        } else {
            evidence.append("coalition_info_resource_usage rc=\(rc) (\(rc == -1 ? "symbol not found" : String(cString: strerror(rc))))")
            let verdict: Verdict = selfRC == 0 ? .estimable : .unavailable
            return ProbeResult(id: 9, metric: "Coalition membership & per-coalition usage", api: "coalition_info (private syscall) + PROC_PIDCOALITIONINFO", verdict: verdict, detail: selfRC == 0 ? "membership readable; per-coalition usage denied — reconstruct from process tree" : "unavailable", evidence: evidence)
        }
    }
}
