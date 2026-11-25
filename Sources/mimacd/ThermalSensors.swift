import Foundation
import IOKit
import MimacCore
import MimacIdentity

/// Turns the SMC's few thousand keys into four numbers a person can act on.
///
/// Sensor keys are model-specific and undocumented, but the naming scheme has
/// held across Apple Silicon: `Tp**` and `Te**` are performance and efficiency
/// core clusters, `Tg**` are GPU clusters, and `Ts0P`/`Ts1P` are the enclosure
/// sensors. Discovery enumerates every key once (~230 ms) and keeps only those
/// that decode to a plausible temperature; sampling then reads that shortlist.
///
/// Reading forty-odd sensors costs a few milliseconds, so the shortlist is read
/// on a slower cadence than the sampler runs and the last reading is carried
/// forward. Silicon this size has enough thermal mass that nothing meaningful
/// happens between refreshes.
final class ThermalSensors {
    /// How often the sensor shortlist is actually re-read.
    private static let refreshInterval: TimeInterval = 10

    /// Anything outside this band is a sensor that is off, unpopulated, or not
    /// a temperature at all, and gets dropped rather than averaged in.
    private static let plausibleRange: ClosedRange<Double> = 5...125

    private let smc: SMCReader?
    private var cpuKeys: [String] = []
    private var gpuKeys: [String] = []
    private var enclosureKeys: [String] = []
    private var discovered = false
    private var lastReading: TemperatureReading?
    private var lastReadAt: Date?

    init() {
        smc = SMCReader()
    }

    var isAvailable: Bool { smc != nil }

    /// The current reading, refreshed at most every `refreshInterval`.
    /// `batteryCelsius` comes from the caller because the gas gauge already
    /// publishes it in the IORegistry — no SMC key needed.
    func read(now: Date, batteryCelsius: Double?) -> TemperatureReading? {
        guard let smc else {
            return batteryCelsius.map { TemperatureReading(batteryCelsius: $0, sensorCount: 1) }
        }
        if let lastReading, let lastReadAt, now.timeIntervalSince(lastReadAt) < Self.refreshInterval {
            // Battery temperature is free, so it stays live between refreshes.
            return TemperatureReading(
                cpuCelsius: lastReading.cpuCelsius,
                gpuCelsius: lastReading.gpuCelsius,
                batteryCelsius: batteryCelsius ?? lastReading.batteryCelsius,
                enclosureCelsius: lastReading.enclosureCelsius,
                sensorCount: lastReading.sensorCount
            )
        }

        if !discovered {
            discover(using: smc)
            discovered = true
        }

        let cpu = hottest(of: cpuKeys, using: smc)
        let gpu = hottest(of: gpuKeys, using: smc)
        let enclosure = hottest(of: enclosureKeys, using: smc)
        let sensorCount = cpuKeys.count + gpuKeys.count + enclosureKeys.count + (batteryCelsius == nil ? 0 : 1)
        let reading = TemperatureReading(
            cpuCelsius: cpu,
            gpuCelsius: gpu,
            batteryCelsius: batteryCelsius,
            enclosureCelsius: enclosure,
            sensorCount: sensorCount
        )
        lastReading = reading
        lastReadAt = now
        return reading.isEmpty ? nil : reading
    }

    /// Battery pack temperature in Celsius from an AppleSmartBattery property
    /// dictionary. The gauge reports centi-Celsius.
    static func batteryCelsius(from properties: [String: Any]) -> Double? {
        guard let raw = (properties["Temperature"] as? NSNumber)?.doubleValue else { return nil }
        let celsius = raw / 100
        return plausibleRange.contains(celsius) ? celsius : nil
    }

    /// Intel Macs name their sensors individually rather than by cluster, so
    /// they are matched exactly. Prefix matching would be wrong on Apple
    /// Silicon, where keys like `TCHP` and `TCMb` share those first letters
    /// without being CPU die sensors. Untested — this machine is Apple Silicon.
    private static let intelCPUKeys: Set<String> = ["TC0P", "TC0E", "TC0F", "TCXC", "TCAD"]
    private static let intelGPUKeys: Set<String> = ["TG0P", "TG0D"]

    private func discover(using smc: SMCReader) {
        for key in smc.allKeyNames() {
            guard key.hasPrefix("T"), let value = smc.value(key), Self.plausibleRange.contains(value) else { continue }
            if key.hasPrefix("Tp") || key.hasPrefix("Te") || Self.intelCPUKeys.contains(key) {
                cpuKeys.append(key)
            } else if key.hasPrefix("Tg") || Self.intelGPUKeys.contains(key) {
                gpuKeys.append(key)
            } else if key == "Ts0P" || key == "Ts1P" {
                // Only these two are enclosure sensors. The rest of the Ts
                // family reads die temperatures despite the shared prefix.
                enclosureKeys.append(key)
            }
        }
    }

    private func hottest(of keys: [String], using smc: SMCReader) -> Double? {
        var peak: Double?
        for key in keys {
            guard let value = smc.value(key), Self.plausibleRange.contains(value) else { continue }
            peak = max(peak ?? value, value)
        }
        return peak
    }
}
