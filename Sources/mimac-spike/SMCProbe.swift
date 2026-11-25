import Foundation
import IOKit
import CShim
import MimacCore

// MARK: - SMC key reads (Appendix A item 11) — SoC power rails, nice-to-have

enum SMCProbe {
    static func probe() -> ProbeResult {
        var evidence: [String] = []
        guard let smc = SMCReader() else {
            return ProbeResult(id: 11, metric: "System/SoC power rails (SMC)", api: "AppleSMC IOUserClient key reads",
                               verdict: .unavailable, detail: "AppleSMC service open failed", evidence: [])
        }
        guard let count = smc.keyCount() else {
            return ProbeResult(id: 11, metric: "System/SoC power rails (SMC)", api: "AppleSMC IOUserClient key reads",
                               verdict: .unavailable, detail: "SMC #KEY read failed", evidence: [])
        }
        evidence.append("SMC reports \(count) keys")

        // Enumerate all keys, decode float 'P***' (power) keys
        var powerKeys: [(String, Double)] = []
        for i in 0..<count {
            guard let k = smc.keyName(at: i), k.hasPrefix("P") else { continue }
            if let v = smc.value(k), v.isFinite, abs(v) < 1000, abs(v) > 0.001 {
                powerKeys.append((k, v))
            }
        }
        evidence.append("Decodable P* (power-candidate) keys: \(powerKeys.count)")
        for (k, v) in powerKeys.sorted(by: { $0.1 > $1.1 }).prefix(15) {
            evidence.append(String(format: "  %@ = %.3f", k, v))
        }
        // Well-known Apple Silicon rails
        for k in ["PSTR", "PDTR", "PHPC", "PPMC", "PMVR"] {
            if let v = smc.value(k) { evidence.append(String(format: "  known key %@ = %.3f W", k, v)) }
        }

        let verdict: Verdict = powerKeys.isEmpty ? .estimable : .measured
        return ProbeResult(id: 11, metric: "System/SoC power rails (SMC)", api: "AppleSMC IOUserClient key reads",
                           verdict: verdict,
                           detail: powerKeys.isEmpty ? "SMC opens but no decodable power keys found" : "\(powerKeys.count) power-rail keys decodable without privileges",
                           evidence: evidence)
    }
}
