import Foundation
import MimacCore
import MimacIdentity

/// Averages the SMC power rails over each sample window.
///
/// The rails refresh about once a second and read instantaneous power, while
/// process energy counters integrate over the whole sample (2 to 30 seconds).
/// Splitting a 30-second counter against a single rail reading would not add
/// up, so this reads the rails on its own timer and integrates them, and the
/// sampler drains the averages once per sample.
///
/// Cost: four SMC reads per tick (~0.1 ms each). The tick slows to every 3 s
/// in the idle modes, where samples are 15–30 s apart anyway.
final class PowerRails {
    struct Average {
        let seconds: Double
        let total: Double?
        let chip: Double?
        let performanceCPU: Double?
        let efficiencyCPU: Double?
        let gpu: Double?

        /// All the rails, or nil when this Mac doesn't publish them. A missing
        /// efficiency-cluster rail only costs the E-core share of the CPU rail.
        var rails: PowerAttribution.Rails? {
            guard let total, let chip, let performanceCPU, let gpu else { return nil }
            return PowerAttribution.Rails(total: total, chip: chip, cpu: performanceCPU + (efficiencyCPU ?? 0), gpu: gpu)
        }
    }

    /// Whole Mac, chip, performance cores, efficiency cores, GPU. Each list is
    /// tried in order; the first key this SMC publishes wins. Only the M5
    /// mapping is verified (see `PowerAttribution`); another chip without
    /// these keys falls back to whole-Mac only.
    private static let keys: [[String]] = [["PSTR"], ["PMVC", "PHPS", "PZC0"], ["PP0b"], ["PPbb"], ["PP1b"]]
    private static var slots: Int { keys.count }

    private let smc = SMCReader()
    private let queue = DispatchQueue(label: "com.mimac.collector.rails", qos: .utility)
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var period: TimeInterval = 1
    private var resolvedKeys: [String?] = []
    private var timebase = mach_timebase_info_data_t()

    // Integration state, guarded by `lock`.
    private var lastReading: [Double?] = []
    private var lastTime: UInt64 = 0
    private var joules = [Double](repeating: 0, count: PowerRails.slots)
    private var covered = [Double](repeating: 0, count: PowerRails.slots)
    private var windowSeconds = 0.0

    init() {
        mach_timebase_info(&timebase)
        resolvedKeys = Self.keys.map { candidates in
            candidates.first { key in smc?.value(key).map { $0.isFinite } ?? false }
        }
        guard resolvedKeys.contains(where: { $0 != nil }) else { return }
        queue.async { self.tick() }
        startTimer()
    }

    deinit { timer?.cancel() }

    /// Faster ticks while someone is watching or the machine is busy; slower
    /// when samples are far apart and nobody is looking.
    func setPeriod(_ seconds: TimeInterval) {
        queue.async {
            guard seconds != self.period else { return }
            self.period = seconds
            self.startTimer()
        }
    }

    /// The averages since the previous drain, closing the window with a fresh
    /// reading so the last partial second counts too.
    func drain() -> Average? {
        guard resolvedKeys.contains(where: { $0 != nil }) else { return nil }
        queue.sync { tick() }
        lock.lock()
        defer {
            joules = [Double](repeating: 0, count: Self.slots)
            covered = [Double](repeating: 0, count: Self.slots)
            windowSeconds = 0
            lock.unlock()
        }
        guard windowSeconds > 0 else { return nil }
        let averages = (0..<Self.slots).map { index -> Double? in
            // A rail that failed for most of the window is not an average.
            covered[index] >= windowSeconds * 0.5 ? joules[index] / covered[index] : nil
        }
        return Average(
            seconds: windowSeconds,
            total: averages[0],
            chip: averages[1],
            performanceCPU: averages[2],
            efficiencyCPU: averages[3],
            gpu: averages[4]
        )
    }

    private func startTimer() {
        timer?.cancel()
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + period, repeating: period, leeway: .milliseconds(Int(period * 250)))
        source.setEventHandler { [weak self] in self?.tick() }
        source.resume()
        timer = source
    }

    /// Trapezoid integration between readings, over awake time, so a sleep
    /// between two ticks adds nothing.
    private func tick() {
        let now = mach_absolute_time()
        let reading: [Double?] = resolvedKeys.map { key in
            guard let key, let value = smc?.value(key), value.isFinite, value >= 0, value < 500 else { return nil }
            return value
        }
        lock.lock()
        defer { lock.unlock() }
        if lastTime != 0 {
            let dt = Double(now - lastTime) * Double(timebase.numer) / Double(timebase.denom) / 1e9
            // A gap well beyond the tick period means the queue stalled; the
            // readings at either end say nothing about the middle.
            if dt > 0, dt <= max(10, period * 4) {
                windowSeconds += dt
                for index in 0..<Self.slots {
                    guard let previous = lastReading[index], let current = reading[index] else { continue }
                    joules[index] += (previous + current) / 2 * dt
                    covered[index] += dt
                }
            }
        }
        lastReading = reading
        lastTime = now
    }
}
