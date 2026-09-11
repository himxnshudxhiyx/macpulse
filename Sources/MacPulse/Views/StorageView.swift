import AppKit
import SwiftUI

struct StorageView: View {
    @EnvironmentObject private var metrics: SystemMetrics

    var body: some View {
        PageScaffold(title: "Storage", subtitle: "\(metrics.volumes.count) mounted volume\(metrics.volumes.count == 1 ? "" : "s")") {
            HStack(spacing: 14) {
                StatTile(title: "Read", value: Fmt.rate(metrics.diskIO.readBytesPerSecond),
                         caption: "\(Fmt.bytes(metrics.diskIO.totalRead)) since boot",
                         systemImage: "arrow.down.circle", tint: .blue)
                StatTile(title: "Write", value: Fmt.rate(metrics.diskIO.writeBytesPerSecond),
                         caption: "\(Fmt.bytes(metrics.diskIO.totalWritten)) since boot",
                         systemImage: "arrow.up.circle", tint: .orange)
                StatTile(title: "Purgeable", value: Fmt.bytes(CacheScanner.purgeableBytes()),
                         caption: "macOS reclaims on demand",
                         systemImage: "sparkles", tint: .teal)
            }

            Card(title: "Disk activity", systemImage: "internaldrive") {
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Read").font(.system(size: 11)).foregroundStyle(.secondary)
                        TrendChart(history: metrics.diskReadHistory, tint: .blue,
                                   valueFormatter: { Fmt.bytes($0) }, height: 80)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Write").font(.system(size: 11)).foregroundStyle(.secondary)
                        TrendChart(history: metrics.diskWriteHistory, tint: .orange,
                                   valueFormatter: { Fmt.bytes($0) }, height: 80)
                    }
                }
            }

            ForEach(metrics.volumes) { volume in
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Image(systemName: volume.isRemovable ? "externaldrive" : (volume.isInternal ? "internaldrive" : "externaldrive.connected.to.line.below"))
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(volume.name).font(.system(size: 13, weight: .semibold))
                                Text("\(volume.path) · \(volume.format)")
                                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Text(Fmt.percent(volume.usedFraction, decimals: 0))
                                .font(.system(size: 15, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(Severity.color(for: volume.usedFraction))
                            Button("Reveal") {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: volume.path)])
                            }
                            .controlSize(.small)
                        }
                        UsageBar(fraction: volume.usedFraction, height: 10)
                        HStack {
                            Text("\(Fmt.bytes(volume.used)) used").font(.system(size: 11)).foregroundStyle(.secondary)
                            Spacer()
                            Text("\(Fmt.bytes(volume.available)) free of \(Fmt.bytes(volume.total))")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if metrics.volumes.isEmpty {
                Card { Text("Reading volumes…").font(.system(size: 12)).foregroundStyle(.secondary) }
            }
        }
    }
}
