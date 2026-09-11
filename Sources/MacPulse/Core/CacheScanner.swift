import Foundation

enum CleanupRisk: String {
    case safe = "Safe"
    case regenerates = "Rebuilds"
    case careful = "Careful"

    var explanation: String {
        switch self {
        case .safe: return "Disposable. Nothing you use will notice."
        case .regenerates: return "Apps rebuild this automatically; the next launch may be slower."
        case .careful: return "Removes real work products. Only clear this if you know you want to."
        }
    }
}

struct CleanupTarget: Identifiable, Hashable {
    let id: String
    let title: String
    let detail: String
    let path: String
    let risk: CleanupRisk

    var url: URL { URL(fileURLWithPath: path) }
    var exists: Bool { FileManager.default.fileExists(atPath: path) }

    var displayPath: String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

struct CleanupScanResult: Identifiable, Hashable {
    var id: String { target.id }
    let target: CleanupTarget
    let size: UInt64
    let itemCount: Int
}

struct CleanupOutcome {
    var freedBytes: UInt64 = 0
    var removedItems: Int = 0
    var failures: [String] = []
}

/// Finds regenerable junk and removes it. Every action is scoped to a fixed
/// allow-list of paths under the user's home directory — nothing outside it is
/// ever a candidate, regardless of what the UI asks for.
final class CacheScanner: @unchecked Sendable {
    private let fileManager = FileManager.default
    private let home = NSHomeDirectory()

    /// Folders owned by TCC-guarded services. Reading them pops a system
    /// permission prompt ("would like to access your media library"), they are
    /// managed by macOS rather than by the user, and they are not ours to
    /// delete — so they are skipped while both scanning and cleaning.
    private static let protectedFragments = [
        "music", "itunes", "media", "photo", "podcast", "appletv",
        "safari", "mail", "message", "addressbook", "contacts",
        "calendar", "reminder", "homekit", "icloud", "knowledge",
        "spotlight", "siri", "healthkit", "screentime",
    ]

    private static let protectedPrefixes = ["com.apple.amp", "com.apple.tv"]

    private func isProtected(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        if Self.protectedPrefixes.contains(where: name.hasPrefix) { return true }
        return Self.protectedFragments.contains(where: name.contains)
    }

    lazy var targets: [CleanupTarget] = {
        func target(_ id: String, _ title: String, _ detail: String, _ relativePath: String,
                    _ risk: CleanupRisk) -> CleanupTarget {
            CleanupTarget(id: id, title: title, detail: detail,
                          path: (home as NSString).appendingPathComponent(relativePath),
                          risk: risk)
        }
        return [
            target("user-caches", "Application Caches", "Cached data written by every app you run.", "Library/Caches", .regenerates),
            target("user-logs", "Application Logs", "Diagnostic logs apps have left behind.", "Library/Logs", .safe),
            target("crash-reports", "Crash Reports", "Saved crash and hang reports.", "Library/Logs/DiagnosticReports", .safe),
            target("trash", "Trash", "Files you already sent to the Trash.", ".Trash", .careful),
            target("saved-state", "Saved Application State", "Window and document state restored when apps reopen.", "Library/Saved Application State", .regenerates),
            target("xcode-derived", "Xcode Derived Data", "Build products and indexes. Xcode rebuilds them on demand.", "Library/Developer/Xcode/DerivedData", .regenerates),
            target("xcode-archives", "Xcode Archives", "Archived builds you may still need for symbolication.", "Library/Developer/Xcode/Archives", .careful),
            target("xcode-devicesupport", "Xcode Device Support", "Symbol caches for devices you've connected.", "Library/Developer/Xcode/iOS DeviceSupport", .regenerates),
            target("simulator-caches", "Simulator Caches", "Cached simulator runtimes and data.", "Library/Developer/CoreSimulator/Caches", .regenerates),
            target("homebrew", "Homebrew Downloads", "Downloaded bottles and source tarballs.", "Library/Caches/Homebrew", .regenerates),
            target("npm", "npm Cache", "Packages npm keeps for offline installs.", ".npm/_cacache", .regenerates),
            target("yarn", "Yarn Cache", "Yarn's global package cache.", "Library/Caches/Yarn", .regenerates),
            target("pip", "pip Cache", "Python wheels pip keeps between installs.", "Library/Caches/pip", .regenerates),
            target("go-build", "Go Build Cache", "Compiled Go packages.", "Library/Caches/go-build", .regenerates),
            target("cargo", "Cargo Registry Cache", "Downloaded Rust crates.", ".cargo/registry/cache", .regenerates),
            target("gradle", "Gradle Caches", "Gradle's dependency and build caches.", ".gradle/caches", .regenerates),
            target("docker-tmp", "Docker Temp", "Temporary files from Docker Desktop.", "Library/Containers/com.docker.docker/Data/tmp", .regenerates),
        ].filter(\.exists)
            // Diagnostic hook: MACPULSE_SCAN_ONLY=<id> narrows the scan to one
            // location, which is how the TCC-prompt sources were tracked down.
            .filter { id in
                guard let only = ProcessInfo.processInfo.environment["MACPULSE_SCAN_ONLY"] else { return true }
                return id.id == only
            }
    }()

    // MARK: - Scanning

    func size(of target: CleanupTarget, isCancelled: () -> Bool = { false }) -> CleanupScanResult {
        var total: UInt64 = 0
        var items = 0
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]

        // Count the immediate children so the UI can say "412 items", then walk
        // the whole tree for the byte total.
        items = ((try? fileManager.contentsOfDirectory(at: target.url, includingPropertiesForKeys: nil)) ?? [])
            .filter { !isProtected($0) }.count

        guard let enumerator = fileManager.enumerator(at: target.url,
                                                      includingPropertiesForKeys: Array(keys),
                                                      options: [.skipsPackageDescendants],
                                                      errorHandler: { _, _ in true }) else {
            return CleanupScanResult(target: target, size: 0, itemCount: items)
        }
        for case let url as URL in enumerator {
            if isCancelled() { break }
            if isProtected(url) {
                enumerator.skipDescendants()
                continue
            }
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            total += UInt64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return CleanupScanResult(target: target, size: total, itemCount: items)
    }

    // MARK: - Cleaning

    func clean(_ target: CleanupTarget, moveToTrash: Bool) -> CleanupOutcome {
        var outcome = CleanupOutcome()
        guard isPermitted(target) else {
            outcome.failures.append("\(target.title): path is outside the allowed cleanup roots.")
            return outcome
        }

        let children: [URL]
        do {
            children = try fileManager.contentsOfDirectory(at: target.url, includingPropertiesForKeys: nil, options: [])
        } catch {
            outcome.failures.append("\(target.title): \(error.localizedDescription)")
            return outcome
        }

        for child in children where !isProtected(child) {
            let reclaimed = size(of: CleanupTarget(id: "", title: "", detail: "", path: child.path, risk: .safe)).size
            let childSize = reclaimed > 0 ? reclaimed : UInt64((try? child.resourceValues(forKeys: [.fileAllocatedSizeKey]).fileAllocatedSize) ?? 0)
            do {
                if moveToTrash {
                    try fileManager.trashItem(at: child, resultingItemURL: nil)
                } else {
                    try fileManager.removeItem(at: child)
                }
                outcome.freedBytes += childSize
                outcome.removedItems += 1
            } catch {
                // Files still open, or protected by SIP, simply stay put.
                outcome.failures.append("\(child.lastPathComponent): \((error as NSError).localizedDescription)")
            }
        }
        return outcome
    }

    /// Only paths inside the user's home directory are ever removable, and the
    /// home directory itself can never be the target.
    private func isPermitted(_ target: CleanupTarget) -> Bool {
        let resolved = URL(fileURLWithPath: target.path).standardizedFileURL.path
        let homeRoot = URL(fileURLWithPath: home).standardizedFileURL.path
        guard resolved != homeRoot, resolved.hasPrefix(homeRoot + "/") else { return false }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: resolved, isDirectory: &isDirectory), isDirectory.boolValue else { return false }
        return true
    }

    /// Space the system is holding as "purgeable" — caches macOS itself will
    /// reclaim when a volume runs low.
    static func purgeableBytes(forVolumeAt path: String = NSHomeDirectory()) -> UInt64 {
        let url = URL(fileURLWithPath: path)
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? url.resourceValues(forKeys: keys),
              let important = values.volumeAvailableCapacityForImportantUsage,
              let free = values.volumeAvailableCapacity else { return 0 }
        return UInt64(max(0, important - Int64(free)))
    }
}
