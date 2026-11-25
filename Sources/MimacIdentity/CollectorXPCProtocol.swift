import Foundation

public let collectorMachService = "com.mimac.collector"

@objc public protocol CollectorXPCProtocol {
    func latestSnapshot(withReply reply: @escaping (NSData?, NSString?) -> Void)
    /// Like `latestSnapshot`, but replies with empty data when the latest sample
    /// still has `sequence`, so a polling client that already holds it skips the
    /// ~600 KB transfer and decode.
    func latestSnapshot(unlessSequence sequence: UInt64, withReply reply: @escaping (NSData?, NSString?) -> Void)
    func health(withReply reply: @escaping (NSData?, NSString?) -> Void)
    func setClientVisible(_ visible: Bool, withReply reply: @escaping (Bool) -> Void)
    func listIdentityRules(withReply reply: @escaping (NSData?, NSString?) -> Void)
    func saveIdentityRule(_ data: NSData, withReply reply: @escaping (NSData?, NSString?) -> Void)
    func deleteIdentityRule(_ id: NSString, withReply reply: @escaping (Bool, NSString?) -> Void)
    func historyStorageHealth(withReply reply: @escaping (NSData?, NSString?) -> Void)
    func historyEntityTimeline(_ request: NSData, withReply reply: @escaping (NSData?, NSString?) -> Void)
    func historyTopEntities(_ request: NSData, withReply reply: @escaping (NSData?, NSString?) -> Void)
    func historyEntityUsage(_ request: NSData, withReply reply: @escaping (NSData?, NSString?) -> Void)
    func historySystemTimeline(_ request: NSData, withReply reply: @escaping (NSData?, NSString?) -> Void)
    func batteryHistory(_ request: NSData, withReply reply: @escaping (NSData?, NSString?) -> Void)
}
