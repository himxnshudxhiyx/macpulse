import SwiftUI

struct CPUView: View {
    @EnvironmentObject private var metrics: SystemMetrics

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 120, maximum: 200), spacing: 10)]
    }

    var body: some View {
        PageScaffold(title: "CPU", subtitle: metrics.systemInfo.chip) {
            Card(title: "Total utilisation", subtitle: Fmt.percent(metrics.cpu.usage), systemImage: "cpu") {
                TrendChart(history: metrics.cpuHistory, tint: .blue, upperBound: 1, height: 120)
                HStack(spacing: 18) {
                    LegendDot(color: .blue, label: "User", value: Fmt.percent(metrics.cpu.user))
                    LegendDot(color: .red, label: "System", value: Fmt.percent(metrics.cpu.system))
                    LegendDot(color: .gray, label: "Idle", value: Fmt.percent(metrics.cpu.idle))
                }
            }

            HStack(spacing: 14) {
                StatTile(title: "1 min load", value: String(format: "%.2f", metrics.cpu.loadAverage[0]),
                         caption: "per-core \(String(format: "%.2f", metrics.cpu.loadAverage[0] / Double(max(1, metrics.systemInfo.totalCores))))",
                         systemImage: "gauge.with.needle", tint: .blue)
                StatTile(title: "5 min load", value: String(format: "%.2f", metrics.cpu.loadAverage[1]),
                         systemImage: "gauge.with.needle", tint: .indigo)
                StatTile(title: "15 min load", value: String(format: "%.2f", metrics.cpu.loadAverage[2]),
                         systemImage: "gauge.with.needle", tint: .purple)
                StatTile(title: "Window peak", value: Fmt.percent(metrics.cpuHistory.peak, decimals: 0),
                         caption: "avg \(Fmt.percent(metrics.cpuHistory.average, decimals: 0))",
                         systemImage: "chart.line.uptrend.xyaxis", tint: .teal)
            }

            if metrics.systemInfo.performanceCores > 0 && metrics.systemInfo.efficiencyCores > 0 {
                Card(title: "Core clusters", systemImage: "square.grid.2x2") {
                    HStack(spacing: 24) {
                        clusterRow(name: "Performance",
                                   count: metrics.systemInfo.performanceCores,
                                   usage: metrics.cpu.performanceUsage,
                                   tint: .orange)
                        clusterRow(name: "Efficiency",
                                   count: metrics.systemInfo.efficiencyCores,
                                   usage: metrics.cpu.efficiencyUsage,
                                   tint: .green)
                    }
                }
            }

            Card(title: "Per-core", subtitle: "\(metrics.cpu.cores.count) logical cores", systemImage: "grid") {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(metrics.cpu.cores) { core in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 4) {
                                Text("Core \(core.id)").font(.system(size: 10, weight: .medium))
                                if core.kind != .unknown {
                                    Text(core.kind.rawValue)
                                        .font(.system(size: 8, weight: .bold))
                                        .padding(.horizontal, 3).padding(.vertical, 1)
                                        .background(core.kind == .performance ? Color.orange.opacity(0.25) : Color.green.opacity(0.25),
                                                    in: RoundedRectangle(cornerRadius: 3))
                                }
                                Spacer()
                                Text(Fmt.percent(core.usage, decimals: 0))
                                    .font(.system(size: 10, weight: .semibold)).monospacedDigit()
                            }
                            UsageBar(fraction: core.usage)
                        }
                    }
                }
            }

            Card(title: "Top processes by CPU", systemImage: "list.number") {
                ProcessCompactList(rows: Array(metrics.processes.sorted { $0.cpu > $1.cpu }.prefix(10))) {
                    String(format: "%.1f%%", $0.cpu)
                }
            }
        }
    }

    private func clusterRow(name: String, count: Int, usage: Double, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(name) · \(count) cores").font(.system(size: 11, weight: .medium))
                Spacer()
                Text(Fmt.percent(usage, decimals: 0)).font(.system(size: 11, weight: .semibold)).monospacedDigit()
            }
            UsageBar(fraction: usage, tint: tint, height: 8)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Small read-only process table reused by the CPU and Memory panels.
struct ProcessCompactList: View {
    let rows: [ProcessInfoRow]
    let value: (ProcessInfoRow) -> String

    var body: some View {
        VStack(spacing: 6) {
            ForEach(rows) { row in
                HStack(spacing: 8) {
                    Text(row.name).font(.system(size: 12)).lineLimit(1)
                    Text("\(row.pid)").font(.system(size: 10)).foregroundStyle(.tertiary).monospacedDigit()
                    Spacer(minLength: 8)
                    Text(row.user).font(.system(size: 10)).foregroundStyle(.secondary)
                    Text(value(row)).font(.system(size: 11, weight: .medium)).monospacedDigit().frame(width: 70, alignment: .trailing)
                }
            }
            if rows.isEmpty {
                Text("Collecting…").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }
}
