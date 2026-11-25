import Foundation
import AppKit
import IOKit
import IOKit.pwr_mgt
import CoreGraphics
import MimacCore

// MARK: - Items 15–19, 21 and NetworkStatistics presence (item 14)

enum MiscProbes {

    // Item 15 — frontmost app
    static func frontmost() -> ProbeResult {
        if let app = NSWorkspace.shared.frontmostApplication {
            return ProbeResult(id: 15, metric: "Frontmost app / app switch events", api: "NSWorkspace",
                               verdict: .measured,
                               detail: "frontmost = \(app.localizedName ?? "?") (pid \(app.processIdentifier))",
                               evidence: ["NSWorkspace.shared.frontmostApplication → \(app.bundleIdentifier ?? "?") pid \(app.processIdentifier)",
                                          "didActivateApplicationNotification available for switch events (not exercised in CLI)"])
        }
        return ProbeResult(id: 15, metric: "Frontmost app / app switch events", api: "NSWorkspace",
                           verdict: .unavailable, detail: "frontmostApplication returned nil (no GUI session?)", evidence: [])
    }

    // Item 16 — power assertions
    static func powerAssertions() -> ProbeResult {
        var dictRef: Unmanaged<CFDictionary>?
        let rc = IOPMCopyAssertionsByProcess(&dictRef)
        guard rc == kIOReturnSuccess, let dict = dictRef?.takeRetainedValue() as? [NSNumber: Any] else {
            return ProbeResult(id: 16, metric: "Power assertions (sleep prevention)", api: "IOPMCopyAssertionsByProcess",
                               verdict: .unavailable, detail: "call failed rc=\(rc)", evidence: [])
        }
        var evidence: [String] = ["Processes holding assertions: \(dict.count)"]
        for (pid, val) in dict.prefix(8) {
            guard let arr = val as? [[String: Any]] else { continue }
            let types = arr.compactMap { $0["AssertType"] as? String }
            let name = ProcAPI.name(for: pid.int32Value)
            evidence.append("  pid \(pid) (\(name)): \(types.joined(separator: ", "))")
        }
        return ProbeResult(id: 16, metric: "Power assertions (sleep prevention)", api: "IOPMCopyAssertionsByProcess",
                           verdict: .measured, detail: "\(dict.count) processes holding assertions, with type + pid", evidence: evidence)
    }

    // Item 17 — thermal state
    static func thermal() -> ProbeResult {
        let state = ProcessInfo.processInfo.thermalState
        let names: [ProcessInfo.ThermalState: String] = [.nominal: "nominal", .fair: "fair", .serious: "serious", .critical: "critical"]
        return ProbeResult(id: 17, metric: "Thermal state", api: "ProcessInfo.thermalState + notification",
                           verdict: .measured, detail: "current = \(names[state] ?? "?") (coarse 4-level, as expected)",
                           evidence: ["ProcessInfo.processInfo.thermalState = \(names[state] ?? "?")"])
    }

    // Item 18 — memory pressure
    static func memoryPressure() -> ProbeResult {
        var evidence: [String] = []
        var verdict: Verdict = .unavailable

        var level: Int32 = 0
        var len = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &len, nil, 0) == 0 {
            let names = [1: "normal", 2: "warning", 4: "critical"]
            evidence.append("kern.memorystatus_vm_pressure_level = \(level) (\(names[Int(level)] ?? "?"))")
            verdict = .measured
        }

        var vmStat = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let hostPort: host_t = mach_host_self()
        let kr = withUnsafeMutablePointer(to: &vmStat) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(hostPort, HOST_VM_INFO64, $0, &count)
            }
        }
        if kr == KERN_SUCCESS {
            let pageSize = UInt64(vm_kernel_page_size)
            evidence.append("host_statistics64: free=\(fmtBytes(UInt64(vmStat.free_count) * pageSize)) compressed=\(fmtBytes(UInt64(vmStat.compressor_page_count) * pageSize)) swapouts=\(vmStat.swapouts)")
            if verdict == .unavailable { verdict = .measured }
        }
        return ProbeResult(id: 18, metric: "Memory pressure", api: "host_statistics64 + memorystatus sysctl",
                           verdict: verdict, detail: evidence.first ?? "no source worked", evidence: evidence)
    }

    // Item 19 — display brightness (private DisplayServices)
    static func brightness() -> ProbeResult {
        typealias GetBrightnessFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
        guard let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY) else {
            return ProbeResult(id: 19, metric: "Display brightness", api: "DisplayServices (private)",
                               verdict: .unavailable, detail: "DisplayServices framework failed to load", evidence: [])
        }
        defer { dlclose(handle) }
        guard let sym = dlsym(handle, "DisplayServicesGetBrightness") else {
            return ProbeResult(id: 19, metric: "Display brightness", api: "DisplayServices (private)",
                               verdict: .unavailable, detail: "DisplayServicesGetBrightness symbol missing", evidence: [])
        }
        let fn = unsafeBitCast(sym, to: GetBrightnessFn.self)
        var value: Float = -1
        let rc = fn(CGMainDisplayID(), &value)
        if rc == 0, value >= 0 {
            return ProbeResult(id: 19, metric: "Display brightness", api: "DisplayServices (private)",
                               verdict: .measured, detail: String(format: "built-in display brightness = %.0f%%", value * 100),
                               evidence: [String(format: "DisplayServicesGetBrightness(main display) = %.3f (rc 0)", value)])
        }
        return ProbeResult(id: 19, metric: "Display brightness", api: "DisplayServices (private)",
                           verdict: .estimable, detail: "symbol present but call failed (rc \(rc)) — fall back to screen-on time only",
                           evidence: ["DisplayServicesGetBrightness rc=\(rc)"])
    }

    // Item 21 — sleep/wake + power source events
    static func powerEvents() -> ProbeResult {
        var notifyPort: IONotificationPortRef?
        var notifier: io_object_t = 0
        let refcon: UnsafeMutableRawPointer? = nil
        let root = IORegisterForSystemPower(refcon, &notifyPort, { _, _, _, _ in }, &notifier)
        var evidence: [String] = []
        var verdict: Verdict = .unavailable
        if root != 0 {
            evidence.append("IORegisterForSystemPower: registration OK (root domain connect \(root))")
            verdict = .measured
            IODeregisterForSystemPower(&notifier)
            IOServiceClose(root)
            if let p = notifyPort { IONotificationPortDestroy(p) }
        } else {
            evidence.append("IORegisterForSystemPower failed")
        }
        evidence.append("Power-source change: IOPSNotificationCreateRunLoopSource available (public); NSWorkspace sleep/wake notifications available")
        return ProbeResult(id: 21, metric: "Sleep/wake & power source events", api: "IOKit power notifications + NSWorkspace",
                           verdict: verdict, detail: verdict == .measured ? "system-power notification registration works" : "registration failed",
                           evidence: evidence)
    }

    // Item 14 — per-process network
    static func network() -> ProbeResult {
        var evidence: [String] = []
        var verdict: Verdict = .unavailable
        var detail = "ntstat unavailable and fd enumeration failed"

        // Private NetworkStatistics.framework presence
        if let handle = dlopen("/System/Library/PrivateFrameworks/NetworkStatistics.framework/NetworkStatistics", RTLD_LAZY) {
            let syms = ["NStatManagerCreate", "NStatManagerAddAllTCP", "NStatSourceSetDescriptionBlock"]
            let found = syms.filter { dlsym(handle, $0) != nil }
            evidence.append("NetworkStatistics.framework loads; symbols present: \(found.joined(separator: ", "))")
            if found.count == syms.count {
                verdict = .estimable
                detail = "private NetworkStatistics.framework present with expected symbols (integration not exercised in spike)"
            }
            dlclose(handle)
        } else {
            evidence.append("NetworkStatistics.framework failed to load")
        }

        // Fallback: socket enumeration via proc_pidfdinfo (existence, not byte counts)
        var socketPids = 0
        var checked = 0
        for pid in ProcAPI.allPids().prefix(400) {
            checked += 1
            if !ProcAPI.listeningPorts(for: pid).isEmpty { socketPids += 1 }
        }
        evidence.append("Fallback fd enumeration: \(socketPids) of \(checked) checked pids expose listening TCP sockets (existence only, no byte counts)")
        if verdict == .unavailable && socketPids > 0 {
            verdict = .estimable
            detail = "socket existence per process readable; byte counts need ntstat or NE extension"
        }
        return ProbeResult(id: 14, metric: "Per-process network", api: "NetworkStatistics (private) / proc_pidfdinfo fallback",
                           verdict: verdict, detail: detail, evidence: evidence)
    }
}
