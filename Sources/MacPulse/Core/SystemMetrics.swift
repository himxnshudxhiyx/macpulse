import AppKit
import Combine
import Foundation

struct HistoryPoint: Identifiable {
    let id = UUID()
    let time: Date
    let value: Double
}

/// A rolling window of samples for the charts. Fixed capacity so memory stays flat.
struct History {
    private(set) var points: [HistoryPoint] = []
    let capacity: Int

    init(capacity: Int = 90) { self.capacity = capacity }

    mutating func append(_ value: Double, at time: Date = Date()) {
        points.append(HistoryPoint(time: time, value: value))
        if points.count > capacity { points.removeFirst(points.count - capacity) }
    }

    var peak: Double { points.map(\.value).max() ?? 0 }
    var average: Double { points.isEmpty ? 0 : points.map(\.value).reduce(0, +) / Double(points.count) }
}

private struct Snapshot {
    var cpu = CPUSample()
    var memory = MemorySample()
    var network = NetworkSample()
    var diskIO = DiskIOSample()
    var power = PowerSample()
    var temperature = TemperatureSample()
    var volumes: [VolumeInfo] = []
    var processes: [ProcessInfoRow]?
}

/// Owns every sampler, drives them on a background queue, and publishes the
/// results as one coherent frame for the UI.
@MainActor
final class SystemMetrics: ObservableObject {
    enum Interval: Double, CaseIterable, Identifiable {
        case fast = 1
        case normal = 2
        case relaxed = 5

        var id: Double { rawValue }
        var label: String {
            switch self {
            case .fast: return "1s"
            case .normal: return "2s"
            case .relaxed: return "5s"
            }
        }
    }

    @Published private(set) var cpu = CPUSample()
    @Published private(set) var memory = MemorySample()
    @Published private(set) var network = NetworkSample()
    @Published private(set) var diskIO = DiskIOSample()
    @Published private(set) var power = PowerSample()
    @Published private(set) var temperature = TemperatureSample()
    @Published private(set) var volumes: [VolumeInfo] = []
    @Published private(set) var processes: [ProcessInfoRow] = []
    @Published private(set) var apps: [RunningAppRow] = []
    @Published private(set) var lastUpdate = Date()

    @Published var interval: Interval = .normal { didSet { restart() } }

    let systemInfo = SystemInfo.load()

    @Published private(set) var cpuHistory = History()
    @Published private(set) var memoryHistory = History()
    @Published private(set) var pressureHistory = History()
    @Published private(set) var downloadHistory = History()
    @Published private(set) var uploadHistory = History()
    @Published private(set) var diskReadHistory = History()
    @Published private(set) var diskWriteHistory = History()
    @Published private(set) var temperatureHistory = History()

    /// Every monitor below keeps rolling state (previous tick counters, previous
    /// byte totals) and is only ever touched from this one serial queue, which
    /// is what makes their `@unchecked Sendable` conformance sound.
    private let queue = DispatchQueue(label: "com.macpulse.sampler", qos: .utility)
    private let cpuMonitor = CPUMonitor()
    private let memoryMonitor = MemoryMonitor()
    private let networkMonitor = NetworkMonitor()
    private let diskMonitor = DiskMonitor()
    private let powerMonitor = PowerMonitor()
    private let processMonitor = ProcessMonitor()
    /// Sensors are read through a provider that builds its client on the
    /// sampler queue; machines whose sensors cannot be read simply report none.
    private let temperatureProvider = TemperatureProvider()

    private var timer: Timer?
    private var tick = 0
    private var isSampling = false

    init() {
        restart()
        sample()
    }

    deinit { timer?.invalidate() }

    private func restart() {
        timer?.invalidate()
        let timer = Timer(timeInterval: interval.rawValue, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
        // Common mode keeps sampling alive while a menu or scroll is tracking.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Forces an immediate refresh, including the process table.
    func refreshNow() {
        tick = 0
        sample()
    }

    private func sample() {
        guard !isSampling else { return }   // a slow frame must not pile up
        isSampling = true

        let includeProcesses = tick % processRefreshDivider == 0
        let includeVolumes = tick % volumeRefreshDivider == 0
        tick &+= 1

        queue.async { [cpuMonitor, memoryMonitor, networkMonitor, diskMonitor, powerMonitor, processMonitor, temperatureProvider] in
            var snapshot = Snapshot()
            snapshot.cpu = cpuMonitor.sample()
            snapshot.memory = memoryMonitor.sample()
            snapshot.network = networkMonitor.sample()
            snapshot.diskIO = diskMonitor.io()
            snapshot.power = powerMonitor.sample()
            snapshot.temperature = temperatureProvider.sample()
            if includeVolumes { snapshot.volumes = diskMonitor.volumes() }
            if includeProcesses { snapshot.processes = processMonitor.processes() }

            let apps = snapshot.processes.map { processMonitor.runningApps(mergedWith: $0) }
            Task { @MainActor [snapshot, apps] in
                self.apply(snapshot, apps: apps, replacedVolumes: includeVolumes)
            }
        }
    }

    private var processRefreshDivider: Int { interval == .fast ? 2 : 1 }
    private var volumeRefreshDivider: Int { max(1, Int(10 / interval.rawValue)) }

    private func apply(_ snapshot: Snapshot, apps: [RunningAppRow]?, replacedVolumes: Bool) {
        cpu = snapshot.cpu
        memory = snapshot.memory
        network = snapshot.network
        diskIO = snapshot.diskIO
        power = snapshot.power
        temperature = snapshot.temperature
        if replacedVolumes { volumes = snapshot.volumes }
        if let processes = snapshot.processes { self.processes = processes }
        if let apps { self.apps = apps }

        let now = Date()
        cpuHistory.append(snapshot.cpu.usage, at: now)
        memoryHistory.append(snapshot.memory.usedFraction, at: now)
        pressureHistory.append(snapshot.memory.pressure, at: now)
        downloadHistory.append(snapshot.network.downloadRate, at: now)
        uploadHistory.append(snapshot.network.uploadRate, at: now)
        diskReadHistory.append(snapshot.diskIO.readBytesPerSecond, at: now)
        diskWriteHistory.append(snapshot.diskIO.writeBytesPerSecond, at: now)
        if let soc = snapshot.temperature.soc { temperatureHistory.append(soc, at: now) }

        lastUpdate = now
        isSampling = false
    }

    // MARK: - Derived

    var bootVolume: VolumeInfo? {
        volumes.first { $0.path == "/" } ?? volumes.first
    }

    /// A single 0–100 read on how much headroom the machine has right now.
    /// Weighted toward the things users actually feel: sustained CPU load,
    /// memory pressure and swapping, and a full boot disk.
    var healthScore: Int {
        var score = 100.0
        score -= cpuHistory.average * 45
        score -= memory.pressure * 35
        if memory.swapUsed > 0 {
            score -= min(15, Double(memory.swapUsed) / 1_073_741_824 * 5)
        }
        if let volume = bootVolume, volume.usedFraction > 0.85 {
            score -= (volume.usedFraction - 0.85) * 100
        }
        switch power.thermalState {
        case .fair: score -= 5
        case .serious: score -= 15
        case .critical: score -= 25
        default: break
        }
        // Sustained high die temperature means the chip is about to throttle,
        // which the thermal state alone reports only once it already has.
        if let soc = temperature.soc, soc > 85 {
            score -= min(12, (soc - 85) * 1.2)
        }
        return Int(max(0, min(100, score.rounded())))
    }

    var healthSummary: String {
        switch healthScore {
        case 85...: return "Excellent"
        case 70..<85: return "Good"
        case 50..<70: return "Under load"
        case 30..<50: return "Strained"
        default: return "Critical"
        }
    }

    /// Concrete, actionable observations rather than a generic warning list.
    var advisories: [Advisory] {
        var items: [Advisory] = []

        if memory.pressure > 0.75 {
            items.append(Advisory(severity: .critical, title: "Memory pressure is high",
                                  detail: "\(Fmt.percent(memory.pressure, decimals: 0)) of RAM is wired or compressed. Quitting a heavy app will help more than anything else."))
        } else if memory.pressure > 0.55 {
            items.append(Advisory(severity: .warning, title: "Memory is getting tight",
                                  detail: "macOS is compressing memory to keep up. Watch the top apps below."))
        }

        if memory.swapUsed > 2 * 1_073_741_824 {
            items.append(Advisory(severity: .warning, title: "Swapping to disk",
                                  detail: "\(Fmt.bytes(memory.swapUsed)) of swap is in use. That is the usual cause of beachballs."))
        }

        if cpuHistory.points.count >= 10, cpuHistory.average > 0.8 {
            items.append(Advisory(severity: .warning, title: "CPU has been pinned",
                                  detail: "Averaging \(Fmt.percent(cpuHistory.average, decimals: 0)) across all cores. Check the top processes."))
        }

        if let volume = bootVolume {
            if volume.usedFraction > 0.95 {
                items.append(Advisory(severity: .critical, title: "Startup disk is nearly full",
                                      detail: "Only \(Fmt.bytes(volume.available)) free. macOS needs headroom for swap and updates."))
            } else if volume.usedFraction > 0.85 {
                items.append(Advisory(severity: .warning, title: "Startup disk is filling up",
                                      detail: "\(Fmt.bytes(volume.available)) free of \(Fmt.bytes(volume.total)). The Cleanup tab can reclaim some of it."))
            }
        }

        if let soc = temperature.soc, soc >= 95 {
            items.append(Advisory(severity: .warning, title: "SoC is running hot",
                                  detail: String(format: "The die is at %.0f °C. Apple silicon throttles rather than overheats, so expect slower clocks until it cools.", soc)))
        }

        if power.thermalState != .nominal {
            items.append(Advisory(severity: power.thermalState == .critical ? .critical : .warning,
                                  title: "Thermal state: \(power.thermalState.label)",
                                  detail: "macOS is throttling to manage heat. Performance will be reduced until it cools."))
        }

        if let health = power.healthFraction, health < 0.8 {
            items.append(Advisory(severity: .info, title: "Battery has aged",
                                  detail: "Full-charge capacity is \(Fmt.percent(health, decimals: 0)) of the original design capacity."))
        }

        if items.isEmpty {
            items.append(Advisory(severity: .good, title: "Nothing needs attention",
                                  detail: "CPU, memory, storage and thermals are all in a comfortable range."))
        }
        return items
    }

    // MARK: - Actions

    func quit(pid: Int32, force: Bool) -> QuitResult {
        let result = force ? processMonitor.forceQuitApp(pid: pid) : processMonitor.quitApp(pid: pid)
        if case .succeeded = result {
            processes.removeAll { $0.pid == pid }
            apps.removeAll { $0.pid == pid }
        }
        return result
    }

    func signal(pid: Int32, force: Bool) -> QuitResult {
        let result = processMonitor.signal(pid: pid, signalNumber: force ? SIGKILL : SIGTERM)
        if case .succeeded = result {
            processes.removeAll { $0.pid == pid }
        }
        return result
    }
}

struct Advisory: Identifiable {
    enum Severity {
        case good, info, warning, critical
    }
    let id = UUID()
    let severity: Severity
    let title: String
    let detail: String
}
