import Darwin
import Foundation

struct CoreSample: Identifiable, Hashable {
    let id: Int
    let user: Double
    let system: Double
    let nice: Double
    var usage: Double { min(1, user + system + nice) }
    /// Performance vs. efficiency core, filled in from the `hw.perflevel*` counts.
    var kind: CoreKind = .unknown
}

enum CoreKind: String {
    case performance = "P"
    case efficiency = "E"
    case unknown = ""
}

struct CPUSample {
    var cores: [CoreSample] = []
    var user: Double = 0
    var system: Double = 0
    var nice: Double = 0
    var usage: Double = 0
    var loadAverage: [Double] = [0, 0, 0]
    var performanceUsage: Double = 0
    var efficiencyUsage: Double = 0

    var idle: Double { max(0, 1 - usage) }
}

/// Per-core utilisation from `host_processor_info`. The kernel reports monotonic
/// tick counters, so usage is the delta between two consecutive reads.
final class CPUMonitor: @unchecked Sendable {
    private var previousTicks: [UInt32] = []
    private let performanceCoreCount = Sysctl.int("hw.perflevel0.logicalcpu") ?? 0
    private let efficiencyCoreCount = Sysctl.int("hw.perflevel1.logicalcpu") ?? 0

    func sample() -> CPUSample {
        var sample = CPUSample()
        sample.loadAverage = Self.loadAverage()

        var cpuCount: natural_t = 0
        var infoArray: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0

        let status = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &infoArray, &infoCount)
        guard status == KERN_SUCCESS, let infoArray else { return sample }
        defer {
            vm_deallocate(mach_task_self_,
                          vm_address_t(bitPattern: infoArray),
                          vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride))
        }

        let states = Int(CPU_STATE_MAX)
        let count = Int(cpuCount)
        var ticks = [UInt32](repeating: 0, count: count * states)
        for index in 0..<(count * states) {
            ticks[index] = UInt32(bitPattern: infoArray[index])
        }

        defer { previousTicks = ticks }
        guard previousTicks.count == ticks.count else {
            // First read has no baseline to diff against; report an idle frame.
            sample.cores = (0..<count).map { CoreSample(id: $0, user: 0, system: 0, nice: 0, kind: coreKind(for: $0)) }
            return sample
        }

        var totalUser = 0.0, totalSystem = 0.0, totalNice = 0.0, totalTicks = 0.0
        var cores: [CoreSample] = []
        cores.reserveCapacity(count)

        for core in 0..<count {
            let base = core * states
            let user = delta(ticks[base + Int(CPU_STATE_USER)], previousTicks[base + Int(CPU_STATE_USER)])
            let system = delta(ticks[base + Int(CPU_STATE_SYSTEM)], previousTicks[base + Int(CPU_STATE_SYSTEM)])
            let idle = delta(ticks[base + Int(CPU_STATE_IDLE)], previousTicks[base + Int(CPU_STATE_IDLE)])
            let nice = delta(ticks[base + Int(CPU_STATE_NICE)], previousTicks[base + Int(CPU_STATE_NICE)])
            let total = user + system + idle + nice

            totalUser += user
            totalSystem += system
            totalNice += nice
            totalTicks += total

            guard total > 0 else {
                cores.append(CoreSample(id: core, user: 0, system: 0, nice: 0, kind: coreKind(for: core)))
                continue
            }
            cores.append(CoreSample(id: core,
                                    user: user / total,
                                    system: system / total,
                                    nice: nice / total,
                                    kind: coreKind(for: core)))
        }

        sample.cores = cores
        if totalTicks > 0 {
            sample.user = totalUser / totalTicks
            sample.system = totalSystem / totalTicks
            sample.nice = totalNice / totalTicks
            sample.usage = min(1, (totalUser + totalSystem + totalNice) / totalTicks)
        }

        let performance = cores.filter { $0.kind == .performance }
        let efficiency = cores.filter { $0.kind == .efficiency }
        sample.performanceUsage = performance.isEmpty ? 0 : performance.map(\.usage).reduce(0, +) / Double(performance.count)
        sample.efficiencyUsage = efficiency.isEmpty ? 0 : efficiency.map(\.usage).reduce(0, +) / Double(efficiency.count)
        return sample
    }

    /// On Apple silicon the kernel enumerates efficiency cores first, then
    /// performance cores.
    private func coreKind(for index: Int) -> CoreKind {
        guard performanceCoreCount > 0, efficiencyCoreCount > 0 else { return .unknown }
        return index < efficiencyCoreCount ? .efficiency : .performance
    }

    /// Tick counters are 32-bit and wrap; treat a decrease as a wrap-around.
    private func delta(_ new: UInt32, _ old: UInt32) -> Double {
        new >= old ? Double(new - old) : Double(new &+ (UInt32.max - old))
    }

    static func loadAverage() -> [Double] {
        var averages = [Double](repeating: 0, count: 3)
        guard getloadavg(&averages, 3) == 3 else { return [0, 0, 0] }
        return averages
    }
}
