import Foundation
import MimacIdentity

struct CalibrationResult: Codable {
    let workload: String
    let startedAt: Date
    let endedAt: Date
    let expectedDominantConsumer: String?
    let observedDominantConsumer: String?
    let dominantConsumerMatched: Bool?
    let counterGapPercent: Double
    let unattributedPercent: Double
    let totalDrainJoules: Double
    let attributedMinutes: Double
    let passesReconciliationCriterion: Bool
}

func usage() -> Never {
    fputs("Usage: mimac-calibrate <workload> --minutes N [--expect name] [-- command ...]\n", stderr)
    fputs("Run unplugged at fixed brightness. Workloads: idle, video, compile, gpu-export, next-churn, agent, download, electron.\n", stderr)
    exit(64)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let workload = arguments.first,
      let minutesIndex = arguments.firstIndex(of: "--minutes"), arguments.indices.contains(minutesIndex + 1),
      let minutes = Double(arguments[minutesIndex + 1]), minutes > 0 else { usage() }
let expected: String? = {
    guard let index = arguments.firstIndex(of: "--expect"), arguments.indices.contains(index + 1) else { return nil }
    return arguments[index + 1]
}()
let command: [String] = {
    guard let index = arguments.firstIndex(of: "--") else { return [] }
    return Array(arguments.dropFirst(index + 1))
}()

let startedAt = Date()
if command.isEmpty {
    Thread.sleep(forTimeInterval: minutes * 60)
} else {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = command
    try process.run()
    process.waitUntilExit()
}
let endedAt = Date()

let connection = NSXPCConnection(machServiceName: collectorMachService)
connection.remoteObjectInterface = NSXPCInterface(with: CollectorXPCProtocol.self)
connection.resume()
defer { connection.invalidate() }
let semaphore = DispatchSemaphore(value: 0)
var report: BatteryHistoryReport?
var failure: String?
let request = BatteryHistoryRequest(range: HistoryRange(start: startedAt, end: endedAt, resolution: .minute))
let payload = try JSONEncoder().encode(request)
guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
    failure = error.localizedDescription
    semaphore.signal()
}) as? CollectorXPCProtocol else { usage() }
proxy.batteryHistory(payload as NSData) { data, error in
    if let error { failure = error as String }
    if let data {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        report = try? decoder.decode(BatteryHistoryReport.self, from: data as Data)
    }
    semaphore.signal()
}
guard semaphore.wait(timeout: .now() + 10) == .success, let report else {
    fputs("mimac-calibrate: \(failure ?? "collector did not return a report")\n", stderr)
    exit(1)
}
let dominant = report.rows.first { $0.category == .entity }
let matched = expected.map { value in dominant?.displayName.localizedCaseInsensitiveContains(value) ?? false }
let unattributed = report.rows.first { $0.category == .unattributed }?.shareOfDrain ?? 0
let result = CalibrationResult(
    workload: workload, startedAt: startedAt, endedAt: endedAt,
    expectedDominantConsumer: expected, observedDominantConsumer: dominant?.displayName,
    dominantConsumerMatched: matched, counterGapPercent: report.reconciliationErrorPercent,
    unattributedPercent: unattributed * 100, totalDrainJoules: report.totalDrainJoules,
    attributedMinutes: report.attributedDurationSeconds / 60,
    passesReconciliationCriterion: unattributed * 100 < 15
)
let encoder = JSONEncoder()
encoder.dateEncodingStrategy = .iso8601
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
FileHandle.standardOutput.write(try encoder.encode(result))
FileHandle.standardOutput.write(Data("\n".utf8))
