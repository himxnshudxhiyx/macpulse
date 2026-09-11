import SwiftUI

struct NetworkView: View {
    @EnvironmentObject private var metrics: SystemMetrics

    var body: some View {
        PageScaffold(title: "Network", subtitle: "Throughput across all interfaces") {
            HStack(spacing: 14) {
                StatTile(title: "Download", value: Fmt.rate(metrics.network.downloadRate),
                         caption: "\(Fmt.bytes(metrics.network.totalIn)) since boot",
                         systemImage: "arrow.down", tint: .blue)
                StatTile(title: "Upload", value: Fmt.rate(metrics.network.uploadRate),
                         caption: "\(Fmt.bytes(metrics.network.totalOut)) since boot",
                         systemImage: "arrow.up", tint: .green)
                StatTile(title: "Peak down", value: Fmt.rate(metrics.downloadHistory.peak),
                         caption: "in this window", systemImage: "chart.line.uptrend.xyaxis", tint: .indigo)
                StatTile(title: "Peak up", value: Fmt.rate(metrics.uploadHistory.peak),
                         caption: "in this window", systemImage: "chart.line.uptrend.xyaxis", tint: .teal)
            }

            Card(title: "Traffic", systemImage: "network") {
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Down").font(.system(size: 11)).foregroundStyle(.secondary)
                        TrendChart(history: metrics.downloadHistory, tint: .blue,
                                   valueFormatter: { Fmt.bytes($0) }, height: 90)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Up").font(.system(size: 11)).foregroundStyle(.secondary)
                        TrendChart(history: metrics.uploadHistory, tint: .green,
                                   valueFormatter: { Fmt.bytes($0) }, height: 90)
                    }
                }
            }

            Card(title: "Interfaces", subtitle: "\(metrics.network.interfaces.count) total", systemImage: "cable.connector") {
                VStack(spacing: 0) {
                    HStack {
                        Text("Interface").frame(width: 80, alignment: .leading)
                        Text("Down").frame(width: 90, alignment: .trailing)
                        Text("Up").frame(width: 90, alignment: .trailing)
                        Text("Received").frame(maxWidth: .infinity, alignment: .trailing)
                        Text("Sent").frame(width: 90, alignment: .trailing)
                        Text("Errors").frame(width: 70, alignment: .trailing)
                    }
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 6)

                    ForEach(metrics.network.interfaces) { interface in
                        HStack {
                            Text(interface.name).frame(width: 80, alignment: .leading)
                                .foregroundStyle(interface.name == "lo0" ? .secondary : .primary)
                            Text(Fmt.rate(interface.downloadRate)).frame(width: 90, alignment: .trailing)
                            Text(Fmt.rate(interface.uploadRate)).frame(width: 90, alignment: .trailing)
                            Text(Fmt.bytes(interface.bytesIn)).frame(maxWidth: .infinity, alignment: .trailing)
                            Text(Fmt.bytes(interface.bytesOut)).frame(width: 90, alignment: .trailing)
                            Text("\(interface.errorsIn + interface.errorsOut)").frame(width: 70, alignment: .trailing)
                                .foregroundStyle((interface.errorsIn + interface.errorsOut) > 0 ? .orange : .secondary)
                        }
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .padding(.vertical, 3)
                    }
                }
            }
        }
    }
}
