import SwiftUI

struct MemoryView: View {
    @EnvironmentObject private var metrics: SystemMetrics

    private var memory: MemorySample { metrics.memory }

    var body: some View {
        PageScaffold(title: "Memory", subtitle: "\(Fmt.bytes(memory.total)) installed") {
            Card(title: "Memory pressure",
                 subtitle: memory.pressureLevel.rawValue,
                 systemImage: "chart.bar.fill") {
                TrendChart(history: metrics.pressureHistory,
                           tint: Severity.color(for: memory.pressure),
                           upperBound: 1, height: 110)
                Text("Pressure — not the amount used — is what tells you whether macOS is struggling. Green means free RAM is available on demand; red means the system is compressing and swapping to keep going.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Card(title: "Breakdown", subtitle: "\(Fmt.bytes(memory.used)) used", systemImage: "memorychip") {
                SegmentedBar(segments: [
                    .init(value: Double(memory.app), color: .blue, label: "App memory"),
                    .init(value: Double(memory.wired), color: .purple, label: "Wired"),
                    .init(value: Double(memory.compressed), color: .orange, label: "Compressed"),
                    .init(value: Double(memory.cachedFiles), color: .green.opacity(0.6), label: "Cached files"),
                ], total: Double(memory.total), height: 14)

                VStack(spacing: 7) {
                    LegendDot(color: .blue, label: "App memory", value: Fmt.bytes(memory.app))
                    LegendDot(color: .purple, label: "Wired (kernel-locked)", value: Fmt.bytes(memory.wired))
                    LegendDot(color: .orange, label: "Compressed", value: Fmt.bytes(memory.compressed))
                    LegendDot(color: .green.opacity(0.6), label: "Cached files (reclaimable)", value: Fmt.bytes(memory.cachedFiles))
                    LegendDot(color: .gray.opacity(0.4), label: "Free", value: Fmt.bytes(memory.free))
                }
                .padding(.top, 2)
            }

            HStack(spacing: 14) {
                StatTile(title: "Used", value: Fmt.bytes(memory.used),
                         caption: Fmt.percent(memory.usedFraction, decimals: 0),
                         systemImage: "memorychip", tint: .blue)
                StatTile(title: "Swap used", value: Fmt.bytes(memory.swapUsed),
                         caption: "of \(Fmt.bytes(memory.swapTotal)) allocated",
                         systemImage: "arrow.left.arrow.right",
                         tint: memory.swapUsed > 0 ? .orange : .green)
                StatTile(title: "Compressions", value: compact(memory.compressions),
                         caption: "since boot", systemImage: "arrow.down.right.and.arrow.up.left", tint: .purple)
                StatTile(title: "Page-outs", value: compact(memory.pageOuts),
                         caption: "since boot", systemImage: "square.and.arrow.down", tint: .teal)
            }

            Card(title: "Usage over time", subtitle: Fmt.percent(memory.usedFraction), systemImage: "chart.line.uptrend.xyaxis") {
                TrendChart(history: metrics.memoryHistory, tint: .blue, upperBound: 1, height: 100)
            }

            Card(title: "Top processes by memory", systemImage: "list.number") {
                ProcessCompactList(rows: Array(metrics.processes.sorted { $0.residentBytes > $1.residentBytes }.prefix(10))) {
                    Fmt.bytes($0.residentBytes)
                }
            }
        }
    }

    private func compact(_ value: UInt64) -> String {
        let number = Double(value)
        switch number {
        case 1_000_000_000...: return String(format: "%.1fB", number / 1_000_000_000)
        case 1_000_000...: return String(format: "%.1fM", number / 1_000_000)
        case 1_000...: return String(format: "%.1fK", number / 1_000)
        default: return "\(value)"
        }
    }
}
