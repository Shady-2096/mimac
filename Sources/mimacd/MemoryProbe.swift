import Foundation
import MimacIdentity

/// Physical memory accounting from `host_statistics64`, split the way macOS
/// splits it so the numbers line up with Activity Monitor.
///
/// The split that matters: app memory is anonymous pages minus what is
/// purgeable, wired is what the kernel cannot page out, and compressed is what
/// has already been squeezed. Those three are the pressure story. File cache is
/// reported separately because the kernel hands it back the moment anything
/// else needs it — counting it as "used" is what makes every naive memory
/// monitor claim a healthy Mac is full.
enum MemoryProbe {
    static func read() -> MemoryReading? {
        var statistics = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &statistics) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let pageSize = UInt64(vm_kernel_page_size)
        let purgeable = UInt64(statistics.purgeable_count)
        let anonymous = UInt64(statistics.internal_page_count)
        let app = anonymous > purgeable ? (anonymous - purgeable) * pageSize : 0

        return MemoryReading(
            totalBytes: totalBytes(),
            appBytes: app,
            wiredBytes: UInt64(statistics.wire_count) * pageSize,
            compressedBytes: UInt64(statistics.compressor_page_count) * pageSize,
            cachedFilesBytes: (UInt64(statistics.external_page_count) + purgeable) * pageSize,
            swapUsedBytes: swapUsedBytes()
        )
    }

    private static func totalBytes() -> UInt64 {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname("hw.memsize", &value, &size, nil, 0) == 0 else {
            return ProcessInfo.processInfo.physicalMemory
        }
        return value
    }

    private static func swapUsedBytes() -> UInt64 {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return 0 }
        return usage.xsu_used
    }
}
