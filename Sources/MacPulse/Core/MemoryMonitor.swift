import Darwin
import Foundation

enum MemoryPressure: String {
    case normal = "Normal"
    case warning = "Warning"
    case critical = "Critical"
    case unknown = "Unknown"
}

struct MemorySample {
    var total: UInt64 = 0
    var app: UInt64 = 0
    var wired: UInt64 = 0
    var compressed: UInt64 = 0
    var cachedFiles: UInt64 = 0
    var free: UInt64 = 0
    var swapUsed: UInt64 = 0
    var swapTotal: UInt64 = 0
    var pressure: Double = 0
    var pressureLevel: MemoryPressure = .unknown
    var pageIns: UInt64 = 0
    var pageOuts: UInt64 = 0
    var compressions: UInt64 = 0
    var decompressions: UInt64 = 0

    /// Matches Activity Monitor's "Memory Used": app + wired + compressed.
    var used: UInt64 { app + wired + compressed }
    var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
    /// What is still available to hand out — cached files count, since macOS
    /// evicts them on demand.
    var available: UInt64 { total > used ? total - used : 0 }
}

/// Virtual-memory statistics from `host_statistics64`, grouped the same way
/// Activity Monitor groups them.
final class MemoryMonitor: @unchecked Sendable {
    private let pageSize: UInt64 = {
        var size: vm_size_t = 0
        host_page_size(mach_host_self(), &size)
        return UInt64(size == 0 ? 4096 : size)
    }()

    private let totalMemory = Sysctl.integer("hw.memsize") ?? 0

    func sample() -> MemorySample {
        var sample = MemorySample()
        sample.total = totalMemory

        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let status = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return sample }

        func bytes(_ pages: some BinaryInteger) -> UInt64 { UInt64(pages) * pageSize }

        let purgeable = bytes(stats.purgeable_count)
        let external = bytes(stats.external_page_count)
        let internalPages = bytes(stats.internal_page_count)

        sample.wired = bytes(stats.wire_count)
        sample.compressed = bytes(stats.compressor_page_count)
        sample.cachedFiles = external + purgeable
        sample.app = internalPages > purgeable ? internalPages - purgeable : internalPages
        sample.free = bytes(stats.free_count) + bytes(stats.speculative_count)
        sample.pageIns = UInt64(stats.pageins)
        sample.pageOuts = UInt64(stats.pageouts)
        sample.compressions = UInt64(stats.compressions)
        sample.decompressions = UInt64(stats.decompressions)

        if let swap = Sysctl.raw("vm.swapusage", as: xsw_usage.self) {
            sample.swapUsed = swap.xsu_used
            sample.swapTotal = swap.xsu_total
        }

        // Kernel pressure level: 1 = normal, 2 = warn, 4 = critical.
        switch Sysctl.int("kern.memorystatus_vm_pressure_level") {
        case 1: sample.pressureLevel = .normal
        case 2: sample.pressureLevel = .warning
        case 4: sample.pressureLevel = .critical
        default: sample.pressureLevel = .unknown
        }

        // Activity Monitor's pressure graph tracks non-reclaimable memory.
        if sample.total > 0 {
            sample.pressure = min(1, Double(sample.wired + sample.compressed) / Double(sample.total))
        }
        return sample
    }
}
