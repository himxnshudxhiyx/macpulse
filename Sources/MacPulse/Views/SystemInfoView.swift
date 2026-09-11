import SwiftUI

struct SystemInfoView: View {
    @EnvironmentObject private var metrics: SystemMetrics
    @EnvironmentObject private var loginItem: LoginItem

    private var info: SystemInfo { metrics.systemInfo }

    var body: some View {
        PageScaffold(title: "System", subtitle: info.marketingName) {
            startupCard

            HStack(alignment: .top, spacing: 14) {
                Card(title: "Hardware", systemImage: "desktopcomputer") {
                    VStack(spacing: 7) {
                        InfoRow(label: "Model", value: info.marketingName)
                        InfoRow(label: "Model identifier", value: info.modelIdentifier)
                        InfoRow(label: "Chip", value: info.chip)
                        InfoRow(label: "Architecture", value: info.architecture)
                        InfoRow(label: "CPU cores", value: coreDescription)
                        if let gpu = info.gpuCores {
                            InfoRow(label: "GPU cores", value: "\(gpu)")
                        }
                        InfoRow(label: "Memory", value: Fmt.bytes(info.physicalMemory))
                    }
                }
                Card(title: "Software", systemImage: "gear") {
                    VStack(spacing: 7) {
                        InfoRow(label: "macOS", value: info.osVersion)
                        InfoRow(label: "Build", value: info.buildVersion)
                        InfoRow(label: "Kernel", value: info.kernelVersion)
                        InfoRow(label: "Host name", value: info.hostName)
                        InfoRow(label: "User", value: info.userName)
                        InfoRow(label: "Booted", value: info.bootTime.formatted(date: .abbreviated, time: .shortened))
                        InfoRow(label: "Uptime", value: Fmt.duration(info.uptime))
                    }
                }
            }

            if metrics.power.hasBattery {
                Card(title: "Battery", systemImage: "battery.100") {
                    HStack(alignment: .top, spacing: 24) {
                        RingGauge(fraction: metrics.power.charge,
                                  label: Fmt.percent(metrics.power.charge, decimals: 0),
                                  caption: metrics.power.isCharging ? "charging" : "charge",
                                  tint: metrics.power.isCharging ? .green : Severity.color(for: 1 - metrics.power.charge),
                                  size: 96)
                        VStack(spacing: 7) {
                            InfoRow(label: "Power source", value: metrics.power.powerSourceName)
                            if let health = metrics.power.healthFraction {
                                InfoRow(label: "Condition", value: Fmt.percent(health, decimals: 0),
                                        valueColor: health < 0.8 ? .orange : .primary)
                            }
                            if let cycles = metrics.power.cycleCount {
                                InfoRow(label: "Cycle count", value: "\(cycles)")
                            }
                            if let design = metrics.power.designCapacity, let max = metrics.power.maxCapacity {
                                InfoRow(label: "Capacity", value: "\(max) / \(design) mAh")
                            }
                            if let temperature = metrics.power.temperatureCelsius {
                                InfoRow(label: "Temperature", value: String(format: "%.1f °C", temperature))
                            }
                            if let minutes = metrics.power.timeToEmptyMinutes {
                                InfoRow(label: "Time remaining", value: "\(minutes / 60)h \(minutes % 60)m")
                            }
                            if let minutes = metrics.power.timeToFullMinutes {
                                InfoRow(label: "Until full", value: "\(minutes / 60)h \(minutes % 60)m")
                            }
                            InfoRow(label: "Thermal state", value: metrics.power.thermalState.label,
                                    valueColor: metrics.power.thermalState == .nominal ? .primary : .orange)
                        }
                    }
                }
            } else {
                Card(title: "Power", systemImage: "powerplug") {
                    VStack(spacing: 7) {
                        InfoRow(label: "Power source", value: metrics.power.powerSourceName)
                        InfoRow(label: "Thermal state", value: metrics.power.thermalState.label,
                                valueColor: metrics.power.thermalState == .nominal ? .primary : .orange)
                    }
                }
            }

            temperatureCard

            Card(title: "Live snapshot", systemImage: "waveform.path.ecg") {
                VStack(spacing: 7) {
                    InfoRow(label: "CPU", value: "\(Fmt.percent(metrics.cpu.usage)) (user \(Fmt.percent(metrics.cpu.user)), system \(Fmt.percent(metrics.cpu.system)))")
                    InfoRow(label: "Load average", value: metrics.cpu.loadAverage.map { String(format: "%.2f", $0) }.joined(separator: "  "))
                    InfoRow(label: "Memory used", value: "\(Fmt.bytes(metrics.memory.used)) of \(Fmt.bytes(metrics.memory.total))")
                    InfoRow(label: "Memory pressure", value: "\(Fmt.percent(metrics.memory.pressure)) — \(metrics.memory.pressureLevel.rawValue)")
                    InfoRow(label: "Swap", value: Fmt.bytes(metrics.memory.swapUsed))
                    InfoRow(label: "Network", value: "↓ \(Fmt.rate(metrics.network.downloadRate))   ↑ \(Fmt.rate(metrics.network.uploadRate))")
                    InfoRow(label: "Disk I/O", value: "↓ \(Fmt.rate(metrics.diskIO.readBytesPerSecond))   ↑ \(Fmt.rate(metrics.diskIO.writeBytesPerSecond))")
                    InfoRow(label: "Processes", value: "\(metrics.processes.count)")
                    InfoRow(label: "Sampled", value: metrics.lastUpdate.formatted(date: .omitted, time: .standard))
                }
            }
        }
    }

    @ViewBuilder
    private var temperatureCard: some View {
        let temperature = metrics.temperature
        if temperature.isAvailable {
            Card(title: "Temperature",
                 subtitle: "\(temperature.sensors.count) sensors",
                 systemImage: "thermometer.medium") {
                HStack(spacing: 14) {
                    if let soc = temperature.soc {
                        temperatureTile("SoC", soc, caption: temperature.socPeak.map { String(format: "peak %.0f °C", $0) })
                    }
                    if let battery = temperature.battery {
                        temperatureTile("Battery", battery, caption: nil)
                    }
                    if let storage = temperature.storage {
                        temperatureTile("SSD", storage, caption: nil)
                    }
                }

                if !metrics.temperatureHistory.points.isEmpty {
                    TrendChart(history: metrics.temperatureHistory,
                               tint: Severity.color(for: (temperature.soc ?? 0) / 100),
                               upperBound: 100,
                               valueFormatter: { String(format: "%.0f°", $0) },
                               height: 90)
                }

                DisclosureGroup("All sensors") {
                    // Two columns; there are dozens of them on Apple silicon.
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())],
                              alignment: .leading, spacing: 4) {
                        ForEach(temperature.sensors) { sensor in
                            HStack {
                                Text(sensor.name).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                                Spacer(minLength: 6)
                                Text(String(format: "%.1f °C", sensor.celsius))
                                    .font(.system(size: 10, weight: .medium)).monospacedDigit()
                            }
                        }
                    }
                    .padding(.top, 6)
                }
                .font(.system(size: 11))

                Text("Apple silicon reports many die sensors; the SoC figure is their average, which is the number that tracks how hard the chip is working.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func temperatureTile(_ title: String, _ celsius: Double, caption: String?) -> some View {
        StatTile(title: title,
                 value: String(format: "%.0f °C", celsius),
                 caption: caption,
                 systemImage: "thermometer.medium",
                 tint: Severity.color(for: celsius / 100))
    }

    private var startupCard: some View {
        Card(title: "Startup", systemImage: "power") {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Toggle("Start MacPulse when I log in", isOn: Binding(
                            get: { loginItem.isEnabled },
                            set: { loginItem.set($0) }))
                            .toggleStyle(.switch)
                            .controlSize(.small)
                        // Spelled out, so the state never depends on reading a
                        // switch's tint.
                        Text(loginItem.isEnabled ? "ENABLED" : "OFF")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 5).padding(.vertical, 1.5)
                            .background((loginItem.isEnabled ? Color.green : Color.secondary).opacity(0.22), in: Capsule())
                            .foregroundStyle(loginItem.isEnabled ? Color.green : .secondary)
                    }
                    Text(loginItem.statusDescription)
                        .font(.system(size: 11))
                        .foregroundStyle(loginItem.lastError == nil ? .secondary : Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if loginItem.needsApproval || loginItem.lastError != nil {
                    Button("Open Login Items") { loginItem.openSystemSettings() }
                        .controlSize(.small)
                }
            }
        }
        .onAppear { loginItem.refresh() }
    }

    private var coreDescription: String {
        if info.performanceCores > 0 && info.efficiencyCores > 0 {
            return "\(info.totalCores) (\(info.performanceCores)P + \(info.efficiencyCores)E)"
        }
        return "\(info.totalCores)"
    }
}
