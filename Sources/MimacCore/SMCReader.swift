import Foundation
import IOKit
import CShim

/// Reads keys out of the AppleSMC user client. Every Mac exposes a few thousand
/// keys — power rails, temperatures, voltages — under four-character codes. The
/// service opens without privileges, and a failed open just means the caller
/// goes without: nothing here is load-bearing.
///
/// Key info (type and size) never changes for the life of a boot, so it is
/// cached after the first read. That halves the IOKit round trips on the
/// sampling path, where the same handful of keys is read over and over.
public final class SMCReader {
    private var connection: io_connect_t = 0
    private var keyInfoCache: [String: cshim_smc_keyinfo] = [:]

    public init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == kIOReturnSuccess else { return nil }
    }

    deinit { if connection != 0 { IOServiceClose(connection) } }

    public static func fourCC(_ key: String) -> UInt32 {
        var value: UInt32 = 0
        for byte in key.utf8 { value = (value << 8) | UInt32(byte) }
        return value
    }

    public static func fourCCString(_ value: UInt32) -> String {
        let bytes = [UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff), UInt8((value >> 8) & 0xff), UInt8(value & 0xff)]
        return String(bytes: bytes, encoding: .ascii) ?? "????"
    }

    /// Number of keys this SMC publishes, or nil when the SMC refuses the read.
    public func keyCount() -> Int? {
        guard let (bytes, _, _) = read("#KEY"), bytes.count >= 4 else { return nil }
        return Int(UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3]))
    }

    /// The key name at an enumeration index. Names are only discoverable this
    /// way — there is no bulk listing — so a full enumeration costs one IOKit
    /// call per key and belongs in setup, not in a sampling loop.
    public func keyName(at index: Int) -> String? {
        var input = cshim_smc_keydata()
        input.data8 = UInt8(CSHIM_SMC_CMD_READ_INDEX)
        input.data32 = UInt32(index)
        guard let output = call(&input), output.result == 0 else { return nil }
        return SMCReader.fourCCString(output.key)
    }

    /// Every key name this SMC publishes.
    public func allKeyNames() -> [String] {
        guard let count = keyCount() else { return [] }
        return (0..<count).compactMap { keyName(at: $0) }
    }

    /// Raw bytes for a key, with its type code and declared size.
    public func read(_ key: String) -> ([UInt8], String, Int)? {
        guard let info = keyInfo(for: key) else { return nil }
        var request = cshim_smc_keydata()
        request.key = SMCReader.fourCC(key)
        request.keyInfo = info
        request.data8 = UInt8(CSHIM_SMC_CMD_READ_BYTES)
        guard let output = call(&request), output.result == 0 else { return nil }

        let size = Int(info.dataSize)
        var bytes = [UInt8](repeating: 0, count: max(size, 4))
        withUnsafeBytes(of: output.bytes) { raw in
            for index in 0..<min(size, 32) { bytes[index] = raw[index] }
        }
        return (Array(bytes.prefix(max(size, 1))), SMCReader.fourCCString(info.dataType), size)
    }

    /// A key decoded to a Double, for the numeric types Apple Silicon actually
    /// uses. Returns nil for types this does not know how to read rather than
    /// guessing at a number.
    public func value(_ key: String) -> Double? {
        guard let (bytes, type, size) = read(key) else { return nil }
        switch type {
        case "flt ":
            guard size >= 4 else { return nil }
            let bits = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            return Double(Float(bitPattern: bits))
        case "ui8 ": return Double(bytes[0])
        case "ui16":
            guard size >= 2 else { return nil }
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        case "ui32":
            guard size >= 4 else { return nil }
            return Double(UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3]))
        case "sp78":
            guard size >= 2 else { return nil }
            return Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256.0
        case "sp87":
            guard size >= 2 else { return nil }
            return Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 128.0
        case "ioft":
            // 6.10 fixed point, little endian, used by the newer sensor keys.
            var raw: UInt64 = 0
            for index in 0..<min(size, 8) { raw |= UInt64(bytes[index]) << (8 * UInt64(index)) }
            return Double(raw) / 65536.0
        default: return nil
        }
    }

    private func keyInfo(for key: String) -> cshim_smc_keyinfo? {
        if let cached = keyInfoCache[key] { return cached }
        var input = cshim_smc_keydata()
        input.key = SMCReader.fourCC(key)
        input.data8 = UInt8(CSHIM_SMC_CMD_READ_KEYINFO)
        guard let output = call(&input), output.result == 0, output.keyInfo.dataSize > 0 else { return nil }
        keyInfoCache[key] = output.keyInfo
        return output.keyInfo
    }

    private func call(_ input: inout cshim_smc_keydata) -> cshim_smc_keydata? {
        var output = cshim_smc_keydata()
        var outputSize = MemoryLayout<cshim_smc_keydata>.size
        let result = IOConnectCallStructMethod(
            connection,
            2 /* kSMCHandleYPCEvent */,
            &input,
            MemoryLayout<cshim_smc_keydata>.size,
            &output,
            &outputSize
        )
        guard result == kIOReturnSuccess else { return nil }
        return output
    }
}
