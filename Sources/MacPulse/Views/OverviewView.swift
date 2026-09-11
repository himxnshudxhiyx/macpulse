import SwiftUI

struct OverviewView: View {
    @EnvironmentObject private var metrics: SystemMetrics
    var onSelect: (Panel) -> Void

    var body: some View {
        PageScaffold(title: "Overview",
                     subtitle: "\(metrics.systemInfo.marketingName) · up \(Fmt.duration(metrics.systemInfo.uptime))") {
            healthCard
            gaugeRow
            advisoryCard
            topConsumers
        }
    }

    private var healthCard: some View {
        Card {
            HStack(alignment: .center, spacing: 20) {
                RingGauge(fraction: Double(metrics.healthScore) / 100,
                          label: "\(metrics.healthScore)",
                          caption: "score",
                          tint: Severity.color(for: 1 - Double(metrics.healthScore) / 100),
                          size: 96)
                VStack(alignment: .leading, spacing: 6) {
                    Text(metrics.healthSummary)
                        .font(.system(size: 20, weight: .bold))
                    Text("Weighted from sustained CPU load, memory pressure, swap use, startup-disk headroom and thermals.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 16) {
                        Label(metrics.power.thermalState.label, systemImage: "thermometer.medium")
                        Label("Load \(String(format: "%.2f", metrics.cpu.loadAverage[0]))", systemImage: "gauge.with.needle")
                        if metrics.power.hasBattery {
                            Label(Fmt.percent(metrics.power.charge, decimals: 0),
                                  systemImage: metrics.power.isCharging ? "battery.100.bolt" : "battery.75")
                        }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                }
                Spacer()
            }
        }
    }

    private var gaugeRow: some View {
        HStack(spacing: 14) {
            miniGauge(title: "CPU",
                      fraction: metrics.cpu.usage,
                      caption: "\(metrics.systemInfo.totalCores) cores",
                      panel: .cpu)
            miniGauge(title: "Memory",
                      fraction: metrics.memory.usedFraction,
                      caption: "\(Fmt.bytes(metrics.memory.used)) of \(Fmt.bytes(metrics.memory.total))",
                      panel: .memory)
            miniGauge(title: "Pressure",
                      fraction: metrics.memory.pressure,
                      caption: metrics.memory.pressureLevel.rawValue,
                      panel: .memory)
            if let volume = metrics.bootVolume {
                miniGauge(title: "Disk",
                          fraction: volume.usedFraction,
                          caption: "\(Fmt.bytes(volume.available)) free",
                          panel: .storage)
            }
        }
    }

    private func miniGauge(title: String, fraction: Double, caption: String, panel: Panel) -> some View {
        Button { onSelect(panel) } label: {
            Card {
                VStack(spacing: 8) {
                    RingGauge(fraction: fraction, label: Fmt.percent(fraction, decimals: 0), caption: title, size: 84)
                    Text(caption)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.plain)
    }

    private var advisoryCard: some View {
        Card(title: "What to look at", systemImage: "checklist") {
            VStack(spacing: 10) {
                ForEach(metrics.advisories) { advisory in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: icon(for: advisory.severity))
                            .foregroundStyle(color(for: advisory.severity))
                            .font(.system(size: 13))
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(advisory.title).font(.system(size: 12, weight: .semibold))
                            Text(advisory.detail)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                    }
                }
            }
        }
    }

    private var topConsumers: some View {
        HStack(alignment: .top, spacing: 14) {
            Card(title: "Top CPU", subtitle: "% of one core", systemImage: "cpu") {
                consumerList(metrics.apps.sorted { $0.cpu > $1.cpu }) { String(format: "%.1f%%", $0.cpu) }
            }
            Card(title: "Top Memory", subtitle: "resident", systemImage: "memorychip") {
                consumerList(metrics.apps.sorted { $0.memoryBytes > $1.memoryBytes }) { Fmt.bytes($0.memoryBytes) }
            }
        }
    }

    private func consumerList(_ apps: [RunningAppRow], value: @escaping (RunningAppRow) -> String) -> some View {
        VStack(spacing: 7) {
            if apps.isEmpty {
                Text("Collecting…").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            ForEach(apps.prefix(5)) { app in
                HStack(spacing: 8) {
                    if let icon = app.icon {
                        Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                    }
                    Text(app.name).font(.system(size: 12)).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(value(app)).font(.system(size: 11, weight: .medium)).monospacedDigit()
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func icon(for severity: Advisory.Severity) -> String {
        switch severity {
        case .good: return "checkmark.circle.fill"
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .critical: return "exclamationmark.octagon.fill"
        }
    }

    private func color(for severity: Advisory.Severity) -> Color {
        switch severity {
        case .good: return .green
        case .info: return .blue
        case .warning: return .orange
        case .critical: return .red
        }
    }
}
