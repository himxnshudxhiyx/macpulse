import AppKit
import Darwin
import Foundation

struct ProcessInfoRow: Identifiable, Hashable {
    let id: Int32
    var pid: Int32 { id }
    let parentPID: Int32
    let user: String
    let cpu: Double          // percent of one core, as reported by the kernel
    let memoryPercent: Double
    let residentBytes: UInt64
    let elapsed: TimeInterval
    let state: String
    let executablePath: String

    var name: String {
        // Strip the bundle scaffolding so "Safari.app/Contents/MacOS/Safari"
        // reads as "Safari".
        let component = (executablePath as NSString).lastPathComponent
        return component.isEmpty ? executablePath : component
    }

    var isAppBundle: Bool { executablePath.contains(".app/Contents/") }

    var stateDescription: String {
        switch state.prefix(1) {
        case "R": return "Running"
        case "S": return "Sleeping"
        case "I": return "Idle"
        case "T": return "Stopped"
        case "U": return "Uninterruptible"
        case "Z": return "Zombie"
        default: return state
        }
    }
}

struct RunningAppRow: Identifiable, Hashable {
    let id: Int32
    var pid: Int32 { id }
    let name: String
    let bundleIdentifier: String?
    let icon: NSImage?
    let isHidden: Bool
    let isActive: Bool
    let launchDate: Date?
    var cpu: Double = 0
    var memoryBytes: UInt64 = 0

    static func == (lhs: RunningAppRow, rhs: RunningAppRow) -> Bool { lhs.id == rhs.id && lhs.cpu == rhs.cpu && lhs.memoryBytes == rhs.memoryBytes }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

enum QuitResult {
    case succeeded
    case failed(String)
}

/// The kernel only hands full accounting for another user's processes to root,
/// so the process table is read through `ps`, which is allowed to report on
/// every process without elevation.
final class ProcessMonitor: @unchecked Sendable {
    func processes() -> [ProcessInfoRow] {
        guard let output = run("/bin/ps", ["-axo", "pid=,ppid=,user=,pcpu=,pmem=,rss=,etime=,state=,comm="]) else { return [] }
        return output.split(separator: "\n").compactMap(parse)
    }

    private func parse(_ line: Substring) -> ProcessInfoRow? {
        // Eight fixed columns, then the executable path, which may contain spaces.
        let fields = line.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: true)
        guard fields.count == 9,
              let pid = Int32(fields[0]),
              let ppid = Int32(fields[1]) else { return nil }
        return ProcessInfoRow(id: pid,
                              parentPID: ppid,
                              user: String(fields[2]),
                              cpu: Double(fields[3]) ?? 0,
                              memoryPercent: Double(fields[4]) ?? 0,
                              residentBytes: (UInt64(fields[5]) ?? 0) * 1024,
                              elapsed: Self.parseElapsed(String(fields[6])),
                              state: String(fields[7]),
                              executablePath: String(fields[8]).trimmingCharacters(in: .whitespaces))
    }

    /// `ps` prints elapsed time as `[[dd-]hh:]mm:ss`.
    static func parseElapsed(_ text: String) -> TimeInterval {
        var days = 0.0
        var remainder = text
        if let dash = text.firstIndex(of: "-") {
            days = Double(text[text.startIndex..<dash]) ?? 0
            remainder = String(text[text.index(after: dash)...])
        }
        let parts = remainder.split(separator: ":").map { Double($0) ?? 0 }
        let hms: Double
        switch parts.count {
        case 3: hms = parts[0] * 3600 + parts[1] * 60 + parts[2]
        case 2: hms = parts[0] * 60 + parts[1]
        case 1: hms = parts[0]
        default: hms = 0
        }
        return days * 86_400 + hms
    }

    func runningApps(mergedWith processes: [ProcessInfoRow]) -> [RunningAppRow] {
        // A single app can span several processes (helpers, XPC services); roll
        // the children up into the app the user recognises.
        var childrenByParent: [Int32: [ProcessInfoRow]] = [:]
        for process in processes {
            childrenByParent[process.parentPID, default: []].append(process)
        }
        let byPID = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })

        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in
                let pid = app.processIdentifier
                guard pid > 0 else { return nil }
                var cpu = 0.0
                var memory: UInt64 = 0
                for process in Self.descendants(of: pid, childrenByParent: childrenByParent, byPID: byPID) {
                    cpu += process.cpu
                    memory += process.residentBytes
                }
                return RunningAppRow(id: pid,
                                     name: app.localizedName ?? "Unknown",
                                     bundleIdentifier: app.bundleIdentifier,
                                     icon: app.icon,
                                     isHidden: app.isHidden,
                                     isActive: app.isActive,
                                     launchDate: app.launchDate,
                                     cpu: cpu,
                                     memoryBytes: memory)
            }
            .sorted { $0.cpu > $1.cpu }
    }

    private static func descendants(of pid: Int32,
                                    childrenByParent: [Int32: [ProcessInfoRow]],
                                    byPID: [Int32: ProcessInfoRow]) -> [ProcessInfoRow] {
        var collected: [ProcessInfoRow] = []
        var queue: [Int32] = [pid]
        var visited: Set<Int32> = []
        while let next = queue.popLast() {
            guard visited.insert(next).inserted else { continue }
            if let process = byPID[next] { collected.append(process) }
            queue.append(contentsOf: (childrenByParent[next] ?? []).map(\.pid))
        }
        return collected
    }

    // MARK: - Termination

    /// Asks an app to quit the way ⌘Q does, so it can save state and prompt
    /// about unsaved documents.
    @discardableResult
    func quitApp(pid: Int32) -> QuitResult {
        guard let app = NSRunningApplication(processIdentifier: pid) else {
            return signal(pid: pid, signalNumber: SIGTERM)
        }
        return app.terminate() ? .succeeded : .failed("\(app.localizedName ?? "The app") refused to quit.")
    }

    @discardableResult
    func forceQuitApp(pid: Int32) -> QuitResult {
        guard let app = NSRunningApplication(processIdentifier: pid) else {
            return signal(pid: pid, signalNumber: SIGKILL)
        }
        return app.forceTerminate() ? .succeeded : .failed("Could not force quit \(app.localizedName ?? "the app").")
    }

    @discardableResult
    func signal(pid: Int32, signalNumber: Int32) -> QuitResult {
        guard pid > 1 else { return .failed("Refusing to signal PID \(pid).") }
        if kill(pid, signalNumber) == 0 { return .succeeded }
        switch errno {
        case EPERM: return .failed("Not permitted — PID \(pid) belongs to another user or is protected by the system.")
        case ESRCH: return .failed("PID \(pid) is no longer running.")
        default: return .failed(String(cString: strerror(errno)))
        }
    }

    private func run(_ launchPath: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}
