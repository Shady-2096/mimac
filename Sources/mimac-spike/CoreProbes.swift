import Foundation
import CShim
import MimacCore

// MARK: - Appendix A items 1–8 and 20, exercised with real data

enum CoreProbes {

    static func run() -> [ProbeResult] {
        var results: [ProbeResult] = []
        let pids = ProcAPI.allPids()
        let selfPid = getpid()

        // 1 — process list
        results.append(ProbeResult(
            id: 1, metric: "Process list", api: "proc_listallpids",
            verdict: pids.count > 10 ? .measured : .unavailable,
            detail: "\(pids.count) pids enumerated",
            evidence: ["proc_listallpids returned \(pids.count) pids as uid \(getuid())"]))

        // 2 — executable path
        var pathOK = 0, pathFail = 0
        var pathSamples: [String] = []
        for pid in pids {
            if let p = ProcAPI.path(for: pid) {
                pathOK += 1
                if pathSamples.count < 3 { pathSamples.append("pid \(pid): \(p)") }
            } else { pathFail += 1 }
        }
        results.append(ProbeResult(
            id: 2, metric: "Executable path", api: "proc_pidpath",
            verdict: pathOK > 0 ? .measured : .unavailable,
            detail: "\(pathOK)/\(pids.count) pids resolved (failures are kernel/other-user procs)",
            evidence: pathSamples + ["resolved: \(pathOK), failed: \(pathFail)"]))

        // 3 — arguments
        var argsOK = 0, argsFail = 0
        var argSample: String?
        for pid in pids {
            if let a = ProcAPI.arguments(for: pid), !a.isEmpty {
                argsOK += 1
                if argSample == nil, a.count > 1 { argSample = "pid \(pid): \(a.joined(separator: " ").prefix(120))" }
            } else { argsFail += 1 }
        }
        results.append(ProbeResult(
            id: 3, metric: "Arguments", api: "sysctl KERN_PROCARGS2",
            verdict: argsOK > 0 ? .measured : .unavailable,
            detail: "\(argsOK)/\(pids.count) pids readable (same-user only, as expected)",
            evidence: [argSample ?? "no multi-arg sample", "readable: \(argsOK), denied/empty: \(argsFail)"]))

        // 4 — working directory
        var cwdOK = 0
        var cwdSamples: [String] = []
        for pid in pids {
            if let c = ProcAPI.cwd(for: pid) {
                cwdOK += 1
                if cwdSamples.count < 3, c != "/" { cwdSamples.append("pid \(pid) (\(ProcAPI.name(for: pid))): \(c)") }
            }
        }
        results.append(ProbeResult(
            id: 4, metric: "Working directory", api: "proc_pidinfo(PROC_PIDVNODEPATHINFO)",
            verdict: cwdOK > 0 ? .measured : .unavailable,
            detail: "\(cwdOK)/\(pids.count) pids readable (same-user)",
            evidence: cwdSamples))

        // 5 — parent / process tree
        var ppidOK = 0
        var treeSample: [String] = []
        for pid in pids {
            if let info = ProcAPI.bsdInfo(for: pid) {
                ppidOK += 1
                if pid == selfPid {
                    // walk own ancestry
                    var cur = pid
                    var chain: [String] = []
                    var hops = 0
                    while cur > 1, hops < 6 {
                        chain.append("\(ProcAPI.name(for: cur))(\(cur))")
                        guard let bi = ProcAPI.bsdInfo(for: cur) else { break }
                        cur = Int32(bi.pbi_ppid); hops += 1
                    }
                    chain.append("launchd(1)")
                    treeSample.append("self ancestry: " + chain.joined(separator: " ← "))
                }
                _ = info
            }
        }
        results.append(ProbeResult(
            id: 5, metric: "Parent / process tree", api: "proc_pidinfo(PROC_PIDTBSDINFO)",
            verdict: ppidOK > 0 ? .measured : .unavailable,
            detail: "ppid readable for \(ppidOK)/\(pids.count) pids; full tree reconstructible",
            evidence: treeSample))

        // 6 — CPU time, memory, disk, wakeups
        var ruOK = 0
        var ruSample: [String] = []
        for pid in pids {
            if let ru = ProcAPI.rusage(for: pid) {
                ruOK += 1
                if ruSample.count < 3, ru.user_time_mach > 0 {
                    let cpu = MachTime.seconds(ru.user_time_mach + ru.system_time_mach)
                    ruSample.append(String(format: "pid %d (%@): cpu=%.1fs mem=%@ diskR=%@ diskW=%@ wakeups=%llu",
                                           pid, ProcAPI.name(for: pid), cpu, fmtBytes(ru.phys_footprint),
                                           fmtBytes(ru.diskio_bytesread), fmtBytes(ru.diskio_byteswritten),
                                           ru.pkg_idle_wkups + ru.interrupt_wkups))
                }
            }
        }
        results.append(ProbeResult(
            id: 6, metric: "CPU time, memory, disk I/O, wakeups", api: "proc_pid_rusage (max flavor V\(cshim_rusage_max_flavor()))",
            verdict: ruOK > 0 ? .measured : .unavailable,
            detail: "rusage readable for \(ruOK)/\(pids.count) pids (same-user; SDK supports V\(cshim_rusage_max_flavor()))",
            evidence: ruSample))

        // 7 — per-process energy: THE load-bearing unknown
        let census = EnergyCensus.run()
        var energyEvidence: [String] = [
            "pids visible: \(census.total), rusage OK: \(census.rusageOK) (denied: \(census.deniedPids))",
            "flavor V6 delivered: \(census.flavor6)",
            "ri_billed_energy > 0: \(census.billedEnergyNonzero) pids",
            "ri_energy_nj  > 0: \(census.energyNJNonzero) pids",
            "ri_penergy_nj > 0 (P-core energy): \(census.penergyNonzero) pids",
        ]
        if !census.topByEnergy.isEmpty {
            energyEvidence.append("Top processes by lifetime CPU energy:")
            for (name, pid, enj, billed) in census.topByEnergy {
                energyEvidence.append(String(format: "  %@ (pid %d): energy_nj=%@ billed=%@", name, pid, fmtJ(enj), fmtJ(billed)))
            }
        }
        // Live accrual check: sample own busy-loop energy delta
        let before = ProcAPI.rusage(for: selfPid)
        let spinUntil = Date().addingTimeInterval(1.0)
        var x = 0.0
        while Date() < spinUntil { x += sin(x) + 1 }
        let after = ProcAPI.rusage(for: selfPid)
        if let b = before, let a = after {
            let dE = a.energy_nj &- b.energy_nj
            let dB = a.billed_energy &- b.billed_energy
            energyEvidence.append(String(format: "Self 1s busy-loop: Δenergy_nj=%@ Δbilled=%@ (x=%.1f)", fmtJ(dE), fmtJ(dB), x))
        }
        let energyVerdict: Verdict = (census.energyNJNonzero > 5 || census.billedEnergyNonzero > 5) ? .measured : .unavailable
        results.append(ProbeResult(
            id: 7, metric: "Per-process energy (nJ)", api: "proc_pid_rusage ri_billed_energy / ri_energy_nj",
            verdict: energyVerdict,
            detail: energyVerdict == .measured
                ? "energy counters POPULATED for third-party caller (\(max(census.energyNJNonzero, census.billedEnergyNonzero)) pids nonzero)"
                : "energy fields present but zero — counters not populated at this privilege level",
            evidence: energyEvidence))

        // 8 — P/E-core & QoS split
        var qosEvidence: [String] = [
            "ri_user_ptime/ri_system_ptime (P-core time) nonzero: \(census.ptimeNonzero) pids",
            "QoS CPU-time buckets nonzero: \(census.qosNonzero) pids",
        ]
        if let ru = ProcAPI.rusage(for: selfPid) {
            let total = MachTime.seconds(ru.user_time_mach + ru.system_time_mach)
            let ptime = MachTime.seconds(ru.user_ptime_mach + ru.system_ptime_mach)
            qosEvidence.append(String(format: "self: total cpu=%.2fs, P-core time=%.2fs (%.0f%%), pcycles=%llu / cycles=%llu",
                                      total, ptime, total > 0 ? ptime / total * 100 : 0, ru.pcycles, ru.cycles))
            qosEvidence.append(String(format: "self QoS buckets (s): default=%.2f UI=%.2f UInit=%.2f util=%.2f bg=%.2f maint=%.2f legacy=%.2f",
                                      MachTime.seconds(ru.qos_default), MachTime.seconds(ru.qos_user_interactive),
                                      MachTime.seconds(ru.qos_user_initiated), MachTime.seconds(ru.qos_utility),
                                      MachTime.seconds(ru.qos_background), MachTime.seconds(ru.qos_maintenance),
                                      MachTime.seconds(ru.qos_legacy)))
        }
        let qosVerdict: Verdict = (census.ptimeNonzero > 5 || census.qosNonzero > 5) ? .measured : .estimable
        results.append(ProbeResult(
            id: 8, metric: "P-core vs E-core / QoS CPU split", api: "RUSAGE_INFO_V6 perf-level fields + QoS buckets",
            verdict: qosVerdict,
            detail: qosVerdict == .measured ? "perf-level time + cycles + QoS buckets all populated" : "QoS buckets only",
            evidence: qosEvidence))

        // 20 — listening ports
        var portEvidence: [String] = []
        var portPids = 0
        for pid in pids {
            let ports = ProcAPI.listeningPorts(for: pid)
            if !ports.isEmpty {
                portPids += 1
                if portEvidence.count < 6 {
                    portEvidence.append("pid \(pid) (\(ProcAPI.name(for: pid))): listening on \(ports.map(String.init).joined(separator: ", "))")
                }
            }
        }
        results.append(ProbeResult(
            id: 20, metric: "Listening ports per process", api: "proc_pidfdinfo socket enumeration",
            verdict: portPids > 0 ? .measured : .unavailable,
            detail: "\(portPids) pids with listening TCP sockets (same-user)",
            evidence: portEvidence))

        return results
    }
}
