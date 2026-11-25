import Foundation
import IOKit
import IOKit.ps

// MARK: - Gas gauge (Appendix A item 10) — ground truth for the energy model

struct BatterySample {
    let timestamp: Date
    let voltageMV: Double
    let amperageMA: Double        // negative = discharging
    let watts: Double             // signed: negative = discharging
    let currentCapacityRaw: Double  // mAh (AppleRawCurrentCapacity)
    let maxCapacityRaw: Double      // mAh (AppleRawMaxCapacity)
    let designCapacity: Double      // mAh
    let cycleCount: Int
    let percent: Int
    let externalConnected: Bool
    let isCharging: Bool
}

enum GasGauge {

    static func service() -> io_service_t {
        IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
    }

    static func sample() -> BatterySample? {
        let svc = service()
        guard svc != 0 else { return nil }
        defer { IOObjectRelease(svc) }

        var propsRef: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(svc, &propsRef, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let props = propsRef?.takeRetainedValue() as? [String: Any] else { return nil }

        func num(_ key: String) -> Double? { (props[key] as? NSNumber)?.doubleValue }

        guard let voltage = num("Voltage") else { return nil }
        // Prefer InstantAmperage; both are signed mA (may arrive as huge UInt64 two's complement)
        var amperage = num("InstantAmperage") ?? num("Amperage") ?? 0
        if amperage > 1e9 {   // two's-complement wrap seen through NSNumber
            amperage = amperage - 18_446_744_073_709_551_616.0
        }
        let rawCur = num("AppleRawCurrentCapacity") ?? num("CurrentCapacity") ?? 0
        let rawMax = num("AppleRawMaxCapacity") ?? num("MaxCapacity") ?? 0
        let design = num("DesignCapacity") ?? 0
        let cycles = Int(num("CycleCount") ?? 0)
        let pct: Int
        if let cc = num("CurrentCapacity"), cc <= 100 { pct = Int(cc) }
        else if rawMax > 0 { pct = Int(rawCur / rawMax * 100) }
        else { pct = 0 }

        let watts = voltage / 1000.0 * amperage / 1000.0
        return BatterySample(
            timestamp: Date(),
            voltageMV: voltage,
            amperageMA: amperage,
            watts: watts,
            currentCapacityRaw: rawCur,
            maxCapacityRaw: rawMax,
            designCapacity: design,
            cycleCount: cycles,
            percent: pct,
            externalConnected: (props["ExternalConnected"] as? Bool) ?? false,
            isCharging: (props["IsCharging"] as? Bool) ?? false
        )
    }

    static func powerSourceType() -> String {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(blob)?.takeRetainedValue() else {
            return "unknown"
        }
        return type as String
    }

    static func probe() -> ProbeResult {
        var evidence: [String] = []
        guard let s = sample() else {
            return ProbeResult(id: 10, metric: "Battery V/I/charge/capacity/cycles", api: "IOKit AppleSmartBattery",
                               verdict: .unavailable, detail: "AppleSmartBattery service not found or unreadable", evidence: [])
        }
        evidence.append(String(format: "Voltage: %.0f mV, InstantAmperage: %.0f mA → %.2f W (%@)",
                               s.voltageMV, s.amperageMA, abs(s.watts), s.watts < 0 ? "discharging" : "charging/idle"))
        evidence.append(String(format: "RawCurrentCapacity: %.0f mAh / RawMaxCapacity: %.0f mAh (design %.0f mAh), cycles %d, charge %d%%",
                               s.currentCapacityRaw, s.maxCapacityRaw, s.designCapacity, s.cycleCount, s.percent))
        evidence.append("Power source: \(powerSourceType()), externalConnected=\(s.externalConnected), isCharging=\(s.isCharging)")

        // Sampling-rate check: take 5 samples at ~0.5 s and verify values refresh
        var distinct = Set<String>()
        var successfulSamples = 0
        for _ in 0..<5 {
            if let x = sample() {
                successfulSamples += 1
                distinct.insert(String(format: "%.0f/%.0f", x.voltageMV, x.amperageMA))
            }
            usleep(500_000)
        }
        evidence.append("5 reads @0.5s: \(successfulSamples) succeeded, \(distinct.count) distinct V/I readings (controller values may remain stable for several seconds)")

        return ProbeResult(id: 10, metric: "Battery V/I/charge/capacity/cycles", api: "IOKit AppleSmartBattery + IOPSCopyPowerSourcesInfo",
                           verdict: successfulSamples == 5 ? .measured : .unavailable,
                           detail: successfulSamples == 5
                               ? String(format: "gas gauge readable repeatedly without privileges; %.2f W now", abs(s.watts))
                               : "gas gauge initial read worked but repeated sampling was unreliable",
                           evidence: evidence)
    }
}
