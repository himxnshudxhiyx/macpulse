import Darwin
import Foundation

/// Thin wrappers around `sysctlbyname` so the rest of the app can read kernel
/// values without repeating the two-pass size/fetch dance every time.
enum Sysctl {
    static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    static func integer(_ name: String) -> UInt64? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0 else { return nil }
        switch size {
        case 8:
            var value: UInt64 = 0
            guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
            return value
        case 4:
            var value: UInt32 = 0
            guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
            return UInt64(value)
        default:
            return nil
        }
    }

    static func int(_ name: String) -> Int? {
        integer(name).map { Int($0) }
    }

    /// Reads an arbitrary fixed-layout struct (`vm.swapusage`, `kern.boottime`, ...).
    static func raw<T>(_ name: String, as type: T.Type) -> T? {
        var size = MemoryLayout<T>.stride
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<T>.alignment)
        defer { pointer.deallocate() }
        guard sysctlbyname(name, pointer, &size, nil, 0) == 0 else { return nil }
        return pointer.load(as: T.self)
    }
}

/// Byte + duration formatting used across every panel, kept in one place so the
/// whole UI speaks the same units.
enum Fmt {
    static func bytes(_ value: UInt64) -> String {
        bytes(Double(value))
    }

    static func bytes(_ value: Double) -> String {
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var amount = value
        var index = 0
        while amount >= 1024, index < units.count - 1 {
            amount /= 1024
            index += 1
        }
        let decimals = (index <= 1 || amount >= 100) ? 0 : (amount >= 10 ? 1 : 2)
        return String(format: "%.\(decimals)f %@", amount, units[index])
    }

    /// Single-character units for places with no room to spare, like the menu bar.
    static func compactBytes(_ value: UInt64) -> String {
        let units = ["B", "K", "M", "G", "T"]
        var amount = Double(value)
        var index = 0
        while amount >= 1024, index < units.count - 1 {
            amount /= 1024
            index += 1
        }
        let decimals = (amount >= 10 || index <= 1) ? 0 : 1
        return String(format: "%.\(decimals)f%@", amount, units[index])
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        bytes(bytesPerSecond) + "/s"
    }

    static func percent(_ fraction: Double, decimals: Int = 1) -> String {
        String(format: "%.\(decimals)f%%", max(0, fraction) * 100)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        if days > 0 { return "\(days)d \(hours)h \(minutes)m" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m \(total % 60)s"
    }
}
