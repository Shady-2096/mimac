import Foundation
import MimacIdentity

enum CollectorClientError: LocalizedError {
    case disconnected
    case invalidReply(String)

    var errorDescription: String? {
        switch self {
        case .disconnected:
            return "The Mimac collector is not running."
        case .invalidReply(let message):
            return message
        }
    }
}

private final class ContinuationGate<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    func resume(returning value: Value) {
        take()?.resume(returning: value)
    }

    func resume(throwing error: Error) {
        take()?.resume(throwing: error)
    }

    private func take() -> CheckedContinuation<Value, Error>? {
        lock.lock()
        defer { lock.unlock() }
        let value = continuation
        continuation = nil
        return value
    }
}

final class CollectorClient: @unchecked Sendable {
    private let lock = NSLock()
    private var connection: NSXPCConnection?
    var onDisconnect: (@Sendable () -> Void)?

    func connect() {
        lock.lock()
        defer { lock.unlock() }
        guard connection == nil else { return }

        let newConnection = NSXPCConnection(machServiceName: collectorMachService)
        newConnection.remoteObjectInterface = NSXPCInterface(with: CollectorXPCProtocol.self)
        newConnection.invalidationHandler = { [weak self, weak newConnection] in
            guard let self else { return }
            lock.lock()
            if connection === newConnection { connection = nil }
            lock.unlock()
            onDisconnect?()
        }
        newConnection.interruptionHandler = { [weak self] in self?.onDisconnect?() }
        connection = newConnection
        newConnection.resume()
    }

    func invalidate() {
        lock.lock()
        let current = connection
        connection = nil
        lock.unlock()
        current?.invalidate()
    }

    /// The latest sample, or nil when it is still `unlessSequence` — the caller
    /// already holds it, so nothing is transferred or decoded.
    func latestSnapshot(unlessSequence known: UInt64?) async throws -> CollectorTelemetry? {
        let data = try await dataCall { proxy, reply in
            if let known {
                proxy.latestSnapshot(unlessSequence: known, withReply: reply)
            } else {
                proxy.latestSnapshot(withReply: reply)
            }
        }
        if data.isEmpty { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(CollectorTelemetry.self, from: data)
    }

    func setVisible(_ visible: Bool) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let gate = ContinuationGate<Void>(continuation)
            do {
                let proxy = try remoteProxy { gate.resume(throwing: $0) }
                proxy.setClientVisible(visible) { acknowledged in
                    acknowledged
                        ? gate.resume(returning: ())
                        : gate.resume(throwing: CollectorClientError.invalidReply("Collector rejected the visibility hint."))
                }
            } catch {
                gate.resume(throwing: error)
            }
        }
    }

    func save(rule: IdentityRule) async throws -> IdentityRule {
        let payload = try JSONEncoder().encode(rule)
        let data = try await dataCall { proxy, reply in
            proxy.saveIdentityRule(payload as NSData, withReply: reply)
        }
        return try JSONDecoder().decode(IdentityRule.self, from: data)
    }

    func entityUsage(minutes: Double) async throws -> [EntityUsageSummary] {
        let end = Date()
        let request = EntityUsageRequest(range: HistoryRange(start: end.addingTimeInterval(-minutes * 60), end: end))
        let payload = try JSONEncoder().encode(request)
        let data = try await dataCall { proxy, reply in
            proxy.historyEntityUsage(payload as NSData, withReply: reply)
        }
        return try JSONDecoder().decode([EntityUsageSummary].self, from: data)
    }

    func batteryHistory(start: Date, end: Date, resolution: HistoryResolution) async throws -> BatteryHistoryReport {
        let request = BatteryHistoryRequest(range: HistoryRange(start: start, end: end, resolution: resolution))
        let payload = try JSONEncoder().encode(request)
        let data = try await dataCall { proxy, reply in
            proxy.batteryHistory(payload as NSData, withReply: reply)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(BatteryHistoryReport.self, from: data)
    }

    private func dataCall(
        _ operation: @escaping (CollectorXPCProtocol, @escaping (NSData?, NSString?) -> Void) -> Void
    ) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let gate = ContinuationGate<Data>(continuation)
            do {
                let proxy = try remoteProxy { gate.resume(throwing: $0) }
                operation(proxy) { data, error in
                    if let error {
                        gate.resume(throwing: CollectorClientError.invalidReply(error as String))
                    } else if let data {
                        gate.resume(returning: data as Data)
                    } else {
                        gate.resume(throwing: CollectorClientError.invalidReply("Collector returned an empty reply."))
                    }
                }
            } catch {
                gate.resume(throwing: error)
            }
        }
    }

    private func remoteProxy(
        errorHandler: @escaping @Sendable (Error) -> Void
    ) throws -> CollectorXPCProtocol {
        lock.lock()
        let current = connection
        lock.unlock()
        guard let current else { throw CollectorClientError.disconnected }
        guard let proxy = current.remoteObjectProxyWithErrorHandler(errorHandler) as? CollectorXPCProtocol else {
            throw CollectorClientError.disconnected
        }
        return proxy
    }
}
