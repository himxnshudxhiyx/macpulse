import SwiftUI

enum Panel: String, CaseIterable, Identifiable {
    case overview, cpu, memory, storage, network, processes, apps, cleanup, system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .cpu: return "CPU"
        case .memory: return "Memory"
        case .storage: return "Storage"
        case .network: return "Network"
        case .processes: return "Processes"
        case .apps: return "Open Apps"
        case .cleanup: return "Cleanup"
        case .system: return "System"
        }
    }

    var symbol: String {
        switch self {
        case .overview: return "speedometer"
        case .cpu: return "cpu"
        case .memory: return "memorychip"
        case .storage: return "internaldrive"
        case .network: return "network"
        case .processes: return "list.bullet.rectangle"
        case .apps: return "square.grid.2x2"
        case .cleanup: return "sparkles"
        case .system: return "desktopcomputer"
        }
    }

    /// `MACPULSE_PANEL=cleanup open -a MacPulse` opens straight to a panel,
    /// which keeps screenshotting and manual testing quick.
    static var initial: Panel {
        ProcessInfo.processInfo.environment["MACPULSE_PANEL"].flatMap(Panel.init(rawValue:)) ?? .overview
    }

    static let monitoring: [Panel] = [.overview, .cpu, .memory, .storage, .network]
    static let management: [Panel] = [.processes, .apps, .cleanup]
    static let about: [Panel] = [.system]
}

struct ContentView: View {
    @EnvironmentObject private var metrics: SystemMetrics
    @State private var selection: Panel = Panel.initial

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Monitor") {
                    ForEach(Panel.monitoring) { panel in
                        row(panel).tag(panel)
                    }
                }
                Section("Manage") {
                    ForEach(Panel.management) { panel in
                        row(panel).tag(panel)
                    }
                }
                Section("About") {
                    ForEach(Panel.about) { panel in
                        row(panel).tag(panel)
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 190, ideal: 205, max: 260)
            .safeAreaInset(edge: .bottom) { sidebarFooter }
        } detail: {
            detail
                .frame(minWidth: 620, minHeight: 480)
                .toolbar { toolbarContent }
        }
        .navigationTitle(selection.title)
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .overview: OverviewView { selection = $0 }
        case .cpu: CPUView()
        case .memory: MemoryView()
        case .storage: StorageView()
        case .network: NetworkView()
        case .processes: ProcessesView()
        case .apps: AppsView()
        case .cleanup: CleanupView()
        case .system: SystemInfoView()
        }
    }

    private func row(_ panel: Panel) -> some View {
        Label(panel.title, systemImage: panel.symbol)
            .badge(badge(for: panel))
    }

    /// Live value on the sidebar row so the numbers are visible without
    /// switching panels.
    private func badge(for panel: Panel) -> Text? {
        switch panel {
        case .cpu: return Text(Fmt.percent(metrics.cpu.usage, decimals: 0))
        case .memory: return Text(Fmt.percent(metrics.memory.usedFraction, decimals: 0))
        case .storage: return metrics.bootVolume.map { Text(Fmt.percent($0.usedFraction, decimals: 0)) }
        case .processes: return Text("\(metrics.processes.count)")
        case .apps: return Text("\(metrics.apps.count)")
        default: return nil
        }
    }

    private var sidebarFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            HStack(spacing: 6) {
                Circle()
                    .fill(Severity.color(for: 1 - Double(metrics.healthScore) / 100))
                    .frame(width: 7, height: 7)
                Text("Health \(metrics.healthScore) · \(metrics.healthSummary)")
                    .font(.system(size: 11))
                Spacer()
            }
            HStack(spacing: 6) {
                Text("Refresh").font(.system(size: 10)).foregroundStyle(.secondary)
                Picker("", selection: Binding(get: { metrics.interval }, set: { metrics.interval = $0 })) {
                    ForEach(SystemMetrics.Interval.allCases) { interval in
                        Text(interval.label).tag(interval)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.mini)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            HStack(spacing: 14) {
                toolbarStat("CPU", Fmt.percent(metrics.cpu.usage, decimals: 0), metrics.cpu.usage)
                toolbarStat("RAM", Fmt.percent(metrics.memory.usedFraction, decimals: 0), metrics.memory.usedFraction)
                toolbarStat("↓", Fmt.rate(metrics.network.downloadRate), 0)
                toolbarStat("↑", Fmt.rate(metrics.network.uploadRate), 0)
            }
            // The toolbar draws its own capsule tight around this content, so
            // the inset has to come from here.
            .padding(.horizontal, 10)
            .padding(.vertical, 2)
            .fixedSize()
        }
        ToolbarItem(placement: .primaryAction) {
            Button { metrics.refreshNow() } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh now")
        }
    }

    private func toolbarStat(_ label: String, _ value: String, _ fraction: Double) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(fraction > 0 ? Severity.color(for: fraction) : .primary)
        }
    }
}
