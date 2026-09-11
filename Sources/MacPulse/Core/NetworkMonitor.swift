import Darwin
import Foundation

struct InterfaceSample: Identifiable, Hashable {
    var id: String { name }
    let name: String
    var bytesIn: UInt64
    var bytesOut: UInt64
    var packetsIn: UInt64
    var packetsOut: UInt64
    var errorsIn: UInt64
    var errorsOut: UInt64
    var downloadRate: Double = 0
    var uploadRate: Double = 0
}

struct NetworkSample {
    var interfaces: [InterfaceSample] = []
    var downloadRate: Double = 0
    var uploadRate: Double = 0
    var totalIn: UInt64 = 0
    var totalOut: UInt64 = 0
}

/// Interface counters via `getifaddrs`, converted to rates between samples.
/// Loopback is listed but excluded from the machine-wide totals.
final class NetworkMonitor: @unchecked Sendable {
    private var previous: [String: (bytesIn: UInt64, bytesOut: UInt64)] = [:]
    private var previousTimestamp: CFAbsoluteTime = 0

    func sample() -> NetworkSample {
        var result = NetworkSample()
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return result }
        defer { freeifaddrs(head) }

        var current: [String: InterfaceSample] = [:]
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = pointer {
            defer { pointer = entry.pointee.ifa_next }
            guard entry.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_LINK),
                  let data = entry.pointee.ifa_data?.assumingMemoryBound(to: if_data.self) else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            current[name] = InterfaceSample(name: name,
                                            bytesIn: UInt64(data.pointee.ifi_ibytes),
                                            bytesOut: UInt64(data.pointee.ifi_obytes),
                                            packetsIn: UInt64(data.pointee.ifi_ipackets),
                                            packetsOut: UInt64(data.pointee.ifi_opackets),
                                            errorsIn: UInt64(data.pointee.ifi_ierrors),
                                            errorsOut: UInt64(data.pointee.ifi_oerrors))
        }

        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - previousTimestamp
        var interfaces: [InterfaceSample] = []

        for var interface in current.values {
            if let old = previous[interface.name], previousTimestamp > 0, elapsed > 0 {
                interface.downloadRate = max(0, Double(interface.bytesIn &- old.bytesIn) / elapsed)
                interface.uploadRate = max(0, Double(interface.bytesOut &- old.bytesOut) / elapsed)
            }
            interfaces.append(interface)
            if interface.name != "lo0" {
                result.downloadRate += interface.downloadRate
                result.uploadRate += interface.uploadRate
                result.totalIn += interface.bytesIn
                result.totalOut += interface.bytesOut
            }
        }

        previous = current.mapValues { ($0.bytesIn, $0.bytesOut) }
        previousTimestamp = now
        result.interfaces = interfaces.sorted {
            ($0.downloadRate + $0.uploadRate, Double($0.bytesIn)) > ($1.downloadRate + $1.uploadRate, Double($1.bytesIn))
        }
        return result
    }
}
