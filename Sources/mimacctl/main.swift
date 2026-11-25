import Foundation
import MimacIdentity

private func connection() -> NSXPCConnection {
    let connection = NSXPCConnection(machServiceName: collectorMachService)
    connection.remoteObjectInterface = NSXPCInterface(with: CollectorXPCProtocol.self)
    connection.resume()
    return connection
}

private func fetch(_ operation: @escaping (CollectorXPCProtocol, @escaping (NSData?, NSString?) -> Void) -> Void) -> Int32 {
    let connection = connection()
    defer { connection.invalidate() }
    let semaphore = DispatchSemaphore(value: 0)
    var exitCode: Int32 = 1
    guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
        fputs("mimacctl: \(error.localizedDescription)\n", stderr)
        semaphore.signal()
    }) as? CollectorXPCProtocol else {
        fputs("mimacctl: could not create XPC proxy\n", stderr)
        return 1
    }
    operation(proxy) { data, error in
        if let error {
            fputs("mimacctl: \(error)\n", stderr)
        } else if let data {
            FileHandle.standardOutput.write(data as Data)
            FileHandle.standardOutput.write(Data("\n".utf8))
            exitCode = 0
        }
        semaphore.signal()
    }
    if semaphore.wait(timeout: .now() + 5) == .timedOut {
        fputs("mimacctl: collector did not reply within 5 seconds\n", stderr)
        return 1
    }
    return exitCode
}

private func setVisible(_ visible: Bool) -> Int32 {
    let connection = connection()
    defer { connection.invalidate() }
    let semaphore = DispatchSemaphore(value: 0)
    var success = false
    guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
        fputs("mimacctl: \(error.localizedDescription)\n", stderr)
        semaphore.signal()
    }) as? CollectorXPCProtocol else { return 1 }
    proxy.setClientVisible(visible) { acknowledged in
        success = acknowledged
        semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + 5)
    return success ? 0 : 1
}

private func deleteRule(_ id: String) -> Int32 {
    let connection = connection()
    defer { connection.invalidate() }
    let semaphore = DispatchSemaphore(value: 0)
    var success = false
    guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
        fputs("mimacctl: \(error.localizedDescription)\n", stderr)
        semaphore.signal()
    }) as? CollectorXPCProtocol else { return 1 }
    proxy.deleteIdentityRule(id as NSString) { deleted, error in
        if let error { fputs("mimacctl: \(error)\n", stderr) }
        success = deleted && error == nil
        semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + 5)
    return success ? 0 : 1
}

private func saveRule(arguments: ArraySlice<String>) -> Int32 {
    let values = Array(arguments)
    guard values.count >= 4,
          let key = IdentityRuleKey(rawValue: values[1]),
          let kind = values.count > 4 ? EntityKind(rawValue: values[4]) : .unknown else {
        fputs("Usage: mimacctl rules save <key> <pattern> <display-name> [kind] [grouping]\n", stderr)
        fputs("Keys: \(IdentityRuleKey.allCases.map(\.rawValue).joined(separator: ", "))\n", stderr)
        fputs("Kinds: \(EntityKind.allCases.map(\.rawValue).joined(separator: ", "))\n", stderr)
        return 64
    }
    let grouping = values.count > 5 ? RuleGrouping(rawValue: values[5]) ?? .standalone : .standalone
    let rule = IdentityRule(key: key, pattern: values[2], displayName: values[3], kind: kind, grouping: grouping)
    guard let data = try? JSONEncoder().encode(rule) else {
        fputs("mimacctl: could not encode rule\n", stderr)
        return 1
    }
    return fetch { proxy, reply in
        proxy.saveIdentityRule(data as NSData, withReply: reply)
    }
}

private func encodedRequest<T: Encodable>(
    _ value: T,
    operation: @escaping (CollectorXPCProtocol, NSData, @escaping (NSData?, NSString?) -> Void) -> Void
) -> Int32 {
    guard let data = try? JSONEncoder().encode(value) else {
        fputs("mimacctl: could not encode history request\n", stderr)
        return 1
    }
    return fetch { proxy, reply in operation(proxy, data as NSData, reply) }
}

private func historyRange(arguments: [String]) -> HistoryRange {
    let hours: Double = {
        if let index = arguments.firstIndex(of: "--days"), arguments.indices.contains(index + 1) {
            return (Double(arguments[index + 1]) ?? 1) * 24
        }
        guard let index = arguments.firstIndex(of: "--hours"), arguments.indices.contains(index + 1) else { return 1 }
        return Double(arguments[index + 1]) ?? 1
    }()
    let resolution: HistoryResolution = {
        guard let index = arguments.firstIndex(of: "--resolution"), arguments.indices.contains(index + 1) else { return .automatic }
        return HistoryResolution(rawValue: arguments[index + 1]) ?? .automatic
    }()
    let end = Date()
    return HistoryRange(start: end.addingTimeInterval(-max(0.01, hours) * 3600), end: end, resolution: resolution)
}

private func history(arguments: [String]) -> Int32 {
    let subcommand = arguments.first ?? "health"
    switch subcommand {
    case "health":
        return fetch { proxy, reply in proxy.historyStorageHealth(withReply: reply) }
    case "entity":
        guard arguments.count >= 2 else {
            fputs("Usage: mimacctl history entity <entity-id> [--hours N] [--resolution raw|minute|hour|day|automatic]\n", stderr)
            return 64
        }
        let request = EntityTimelineRequest(entityID: arguments[1], range: historyRange(arguments: arguments))
        return encodedRequest(request) { proxy, data, reply in proxy.historyEntityTimeline(data, withReply: reply) }
    case "top":
        let metric = arguments.count >= 2 ? HistoryMetric(rawValue: arguments[1]) ?? .energyJoules : .energyJoules
        let limit: Int = {
            guard let index = arguments.firstIndex(of: "--limit"), arguments.indices.contains(index + 1) else { return 10 }
            return Int(arguments[index + 1]) ?? 10
        }()
        let request = TopEntitiesRequest(range: historyRange(arguments: arguments), metric: metric, limit: limit)
        return encodedRequest(request) { proxy, data, reply in proxy.historyTopEntities(data, withReply: reply) }
    case "system":
        let range = historyRange(arguments: arguments)
        return encodedRequest(range) { proxy, data, reply in proxy.historySystemTimeline(data, withReply: reply) }
    case "usage":
        let request = EntityUsageRequest(range: historyRange(arguments: arguments))
        return encodedRequest(request) { proxy, data, reply in proxy.historyEntityUsage(data, withReply: reply) }
    default:
        fputs("Usage: mimacctl history health|entity|top|usage|system\n", stderr)
        return 64
    }
}

private func battery(arguments: [String]) -> Int32 {
    let request = BatteryHistoryRequest(range: historyRange(arguments: arguments))
    return encodedRequest(request) { proxy, data, reply in proxy.batteryHistory(data, withReply: reply) }
}

private func watch() -> Int32 {
    let connection = connection()
    let failed = DispatchSemaphore(value: 0)
    guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
        fputs("mimacctl: \(error.localizedDescription)\n", stderr)
        failed.signal()
    }) as? CollectorXPCProtocol else { return 1 }

    let visibleReply = DispatchSemaphore(value: 0)
    proxy.setClientVisible(true) { _ in visibleReply.signal() }
    guard visibleReply.wait(timeout: .now() + 5) == .success else { return 1 }
    while true {
        let reply = DispatchSemaphore(value: 0)
        proxy.latestSnapshot { data, error in
            if let error {
                fputs("mimacctl: \(error)\n", stderr)
            } else if let data {
                FileHandle.standardOutput.write(data as Data)
                FileHandle.standardOutput.write(Data("\n".utf8))
            }
            reply.signal()
        }
        if reply.wait(timeout: .now() + 5) == .timedOut || failed.wait(timeout: .now()) == .success {
            connection.invalidate()
            return 1
        }
        Thread.sleep(forTimeInterval: 2)
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
let command = arguments.first ?? "snapshot"
let code: Int32
switch command {
case "snapshot":
    code = fetch { proxy, reply in proxy.latestSnapshot(withReply: reply) }
case "health":
    code = fetch { proxy, reply in proxy.health(withReply: reply) }
case "watch":
    code = watch()
case "visible":
    guard arguments.count == 2, ["true", "false"].contains(arguments[1]) else {
        fputs("Usage: mimacctl visible true|false\n", stderr)
        exit(64)
    }
    code = setVisible(arguments[1] == "true")
case "rules":
    switch arguments.dropFirst().first {
    case "list", nil:
        code = fetch { proxy, reply in proxy.listIdentityRules(withReply: reply) }
    case "save":
        code = saveRule(arguments: arguments.dropFirst())
    case "delete":
        guard arguments.count == 3 else {
            fputs("Usage: mimacctl rules delete <rule-id>\n", stderr)
            exit(64)
        }
        code = deleteRule(arguments[2])
    default:
        fputs("Usage: mimacctl rules list|save|delete\n", stderr)
        exit(64)
    }
case "history":
    code = history(arguments: Array(arguments.dropFirst()))
case "battery":
    code = battery(arguments: Array(arguments.dropFirst()))
case "--help", "-h", "help":
    print("Usage: mimacctl snapshot|health|watch|visible true|false|rules list|rules save|rules delete|history health|history entity|history top|history system|battery [--hours N | --days 7|30] [--resolution minute|hour|day]")
    code = 0
default:
    fputs("Unknown command: \(command). Run mimacctl --help.\n", stderr)
    code = 64
}
exit(code)
