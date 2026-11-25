import Foundation
import MimacIdentity

let collector = Collector()
collector.start()

if CommandLine.arguments.contains("--stdio") {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let once = CommandLine.arguments.contains("--once")
    repeat {
        Thread.sleep(forTimeInterval: once ? 1.2 : 2.2)
        if let snapshot = collector.snapshot(), let data = try? encoder.encode(snapshot) {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        }
    } while !once
    exit(0)
}

let service = CollectorXPCService(collector: collector)
let listener = NSXPCListener(machServiceName: collectorMachService)
listener.delegate = service
listener.resume()
RunLoop.current.run()
