import Foundation
import MimacIdentity

final class CollectorXPCService: NSObject, NSXPCListenerDelegate {
    private let collector: Collector

    init(collector: Collector) {
        self.collector = collector
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let session = CollectorXPCSession(collector: collector)
        connection.exportedInterface = NSXPCInterface(with: CollectorXPCProtocol.self)
        connection.exportedObject = session
        connection.invalidationHandler = { session.disconnect() }
        connection.resume()
        return true
    }
}

private final class CollectorXPCSession: NSObject, CollectorXPCProtocol {
    private let collector: Collector
    private let clientID = UUID()
    private let encoder: JSONEncoder
    private var disconnected = false

    init(collector: Collector) {
        self.collector = collector
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
    }

    func latestSnapshot(withReply reply: @escaping (NSData?, NSString?) -> Void) {
        snapshotData(unlessSequence: nil, reply: reply)
    }

    func latestSnapshot(unlessSequence sequence: UInt64, withReply reply: @escaping (NSData?, NSString?) -> Void) {
        snapshotData(unlessSequence: sequence, reply: reply)
    }

    private func snapshotData(unlessSequence sequence: UInt64?, reply: @escaping (NSData?, NSString?) -> Void) {
        do {
            guard let data = try collector.snapshotData(unlessSequence: sequence) else {
                reply(nil, "collector has not completed its first sample")
                return
            }
            reply(data as NSData, nil)
        } catch {
            reply(nil, error.localizedDescription as NSString)
        }
    }

    func health(withReply reply: @escaping (NSData?, NSString?) -> Void) {
        encode(collector.health(), reply: reply)
    }

    func setClientVisible(_ visible: Bool, withReply reply: @escaping (Bool) -> Void) {
        collector.setClientVisible(visible, clientID: clientID)
        reply(true)
    }

    func listIdentityRules(withReply reply: @escaping (NSData?, NSString?) -> Void) {
        encode(collector.listIdentityRules(), reply: reply)
    }

    func saveIdentityRule(_ data: NSData, withReply reply: @escaping (NSData?, NSString?) -> Void) {
        do {
            let decoder = JSONDecoder()
            let rule = try decoder.decode(IdentityRule.self, from: data as Data)
            let saved = try collector.saveIdentityRule(rule)
            encode(saved, reply: reply)
        } catch {
            reply(nil, error.localizedDescription as NSString)
        }
    }

    func deleteIdentityRule(_ id: NSString, withReply reply: @escaping (Bool, NSString?) -> Void) {
        do {
            reply(try collector.deleteIdentityRule(id: id as String), nil)
        } catch {
            reply(false, error.localizedDescription as NSString)
        }
    }

    func historyStorageHealth(withReply reply: @escaping (NSData?, NSString?) -> Void) {
        do {
            encode(try collector.historyStorageHealth(), reply: reply)
        } catch {
            reply(nil, error.localizedDescription as NSString)
        }
    }

    func historyEntityTimeline(_ request: NSData, withReply reply: @escaping (NSData?, NSString?) -> Void) {
        decode(EntityTimelineRequest.self, from: request, reply: reply) { value in
            try collector.historyEntityTimeline(value)
        }
    }

    func historyTopEntities(_ request: NSData, withReply reply: @escaping (NSData?, NSString?) -> Void) {
        decode(TopEntitiesRequest.self, from: request, reply: reply) { value in
            try collector.historyTopEntities(value)
        }
    }

    func historyEntityUsage(_ request: NSData, withReply reply: @escaping (NSData?, NSString?) -> Void) {
        decode(EntityUsageRequest.self, from: request, reply: reply) { value in
            try collector.historyEntityUsage(value)
        }
    }

    func historySystemTimeline(_ request: NSData, withReply reply: @escaping (NSData?, NSString?) -> Void) {
        decode(HistoryRange.self, from: request, reply: reply) { value in
            try collector.historySystemTimeline(value)
        }
    }

    func batteryHistory(_ request: NSData, withReply reply: @escaping (NSData?, NSString?) -> Void) {
        decode(BatteryHistoryRequest.self, from: request, reply: reply) { value in
            try collector.batteryHistory(value)
        }
    }

    func disconnect() {
        guard !disconnected else { return }
        disconnected = true
        collector.removeClient(clientID)
    }

    private func encode<T: Encodable>(_ value: T, reply: @escaping (NSData?, NSString?) -> Void) {
        do {
            reply(try encoder.encode(value) as NSData, nil)
        } catch {
            reply(nil, error.localizedDescription as NSString)
        }
    }

    private func decode<Input: Decodable, Output: Encodable>(
        _ type: Input.Type,
        from data: NSData,
        reply: @escaping (NSData?, NSString?) -> Void,
        operation: (Input) throws -> Output
    ) {
        do {
            let value = try JSONDecoder().decode(type, from: data as Data)
            encode(try operation(value), reply: reply)
        } catch {
            reply(nil, error.localizedDescription as NSString)
        }
    }
}
