import AppKit
import SwiftUI

struct ProcessesView: View {
    @EnvironmentObject private var metrics: SystemMetrics
    @State private var search = ""
    @State private var sortOrder = [KeyPathComparator(\ProcessInfoRow.cpu, order: .reverse)]
    @State private var selection: Set<Int32> = []
    @State private var pendingKill: PendingAction?
    @State private var errorMessage: String?
    @State private var showSystemProcesses = true

    private struct PendingAction: Identifiable {
        let id = UUID()
        let row: ProcessInfoRow
        let force: Bool
    }

    private var rows: [ProcessInfoRow] {
        var result = metrics.processes
        if !showSystemProcesses {
            result = result.filter { $0.user == NSUserName() }
        }
        if !search.isEmpty {
            let needle = search.lowercased()
            result = result.filter {
                $0.name.lowercased().contains(needle)
                || $0.executablePath.lowercased().contains(needle)
                || String($0.pid) == needle
            }
        }
        return result.sorted(using: sortOrder)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Table(rows, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Process", value: \.name) { row in
                    HStack(spacing: 6) {
                        Image(systemName: row.isAppBundle ? "app.dashed" : "terminal")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                        Text(row.name).lineLimit(1).help(row.executablePath)
                    }
                }
                .width(min: 130, ideal: 220)

                TableColumn("PID", value: \.pid) { row in
                    Text("\(row.pid)").monospacedDigit().foregroundStyle(.secondary)
                }
                .width(60)

                TableColumn("CPU", value: \.cpu) { row in
                    Text(String(format: "%.1f%%", row.cpu))
                        .monospacedDigit()
                        .foregroundStyle(row.cpu > 50 ? Color.orange : .primary)
                }
                .width(64)

                TableColumn("Memory", value: \.residentBytes) { row in
                    Text(Fmt.bytes(row.residentBytes)).monospacedDigit()
                }
                .width(84)

                TableColumn("User", value: \.user) { row in
                    Text(row.user).foregroundStyle(.secondary).lineLimit(1)
                }
                .width(84)

                TableColumn("Uptime", value: \.elapsed) { row in
                    Text(Fmt.duration(row.elapsed)).monospacedDigit().foregroundStyle(.secondary)
                }
                .width(80)

                TableColumn("State", value: \.state) { row in
                    Text(row.stateDescription).foregroundStyle(.secondary).lineLimit(1)
                }
                .width(82)

                TableColumn("") { row in
                    HStack(spacing: 4) {
                        Button("Quit") { pendingKill = PendingAction(row: row, force: false) }
                        Button("Force") { pendingKill = PendingAction(row: row, force: true) }
                            .tint(.red)
                    }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                }
                .width(104)
            }
            .contextMenu(forSelectionType: Int32.self) { selected in
                if let pid = selected.first, let row = rows.first(where: { $0.pid == pid }) {
                    Button("Quit \(row.name)") { pendingKill = PendingAction(row: row, force: false) }
                    Button("Force Quit \(row.name)") { pendingKill = PendingAction(row: row, force: true) }
                    Divider()
                    Button("Copy PID") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("\(row.pid)", forType: .string)
                    }
                    Button("Copy Path") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(row.executablePath, forType: .string)
                    }
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: row.executablePath)])
                    }
                }
            }
        }
        .background(.background)
        .alert(item: $pendingKill) { pending in
            Alert(title: Text(pending.force ? "Force quit \(pending.row.name)?" : "Quit \(pending.row.name)?"),
                  message: Text(pending.force
                                ? "SIGKILL ends PID \(pending.row.pid) immediately. Unsaved work in that process is lost, and it cannot clean up after itself."
                                : "Sends SIGTERM to PID \(pending.row.pid) so it can shut down normally."),
                  primaryButton: .destructive(Text(pending.force ? "Force Quit" : "Quit")) {
                      perform(pending)
                  },
                  secondaryButton: .cancel())
        }
        .alert("Couldn't quit that process",
               isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Processes").font(.system(size: 18, weight: .bold))
                Text("\(rows.count) shown · \(metrics.processes.count) running")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("All users", isOn: $showSystemProcesses)
                .toggleStyle(.switch)
                .controlSize(.small)
            TextField("Filter by name or PID", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
            Button {
                metrics.refreshNow()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh now")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func perform(_ pending: PendingAction) {
        // Apps get the polite AppKit path so they can save state; everything
        // else is signalled directly.
        let result = pending.row.isAppBundle && NSRunningApplication(processIdentifier: pending.row.pid) != nil
            ? metrics.quit(pid: pending.row.pid, force: pending.force)
            : metrics.signal(pid: pending.row.pid, force: pending.force)
        if case .failed(let message) = result { errorMessage = message }
    }
}
