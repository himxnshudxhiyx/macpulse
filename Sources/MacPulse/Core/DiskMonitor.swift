import Foundation
import IOKit

struct VolumeInfo: Identifiable, Hashable {
    var id: String { path }
    let name: String
    let path: String
    let total: UInt64
    let available: UInt64
    let isInternal: Bool
    let isRemovable: Bool
    let format: String

    var used: UInt64 { total > available ? total - available : 0 }
    var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
}

struct DiskIOSample {
    var readBytesPerSecond: Double = 0
    var writeBytesPerSecond: Double = 0
    var totalRead: UInt64 = 0
    var totalWritten: UInt64 = 0
}

final class DiskMonitor: @unchecked Sendable {
    private var previousRead: UInt64 = 0
    private var previousWritten: UInt64 = 0
    private var previousTimestamp: CFAbsoluteTime = 0

    func volumes() -> [VolumeInfo] {
        let keys: [URLResourceKey] = [
            .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey, .volumeIsInternalKey, .volumeIsRemovableKey,
            .volumeIsBrowsableKey, .volumeLocalizedFormatDescriptionKey,
        ]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                         options: [.skipHiddenVolumes]) ?? []
        var seen = Set<String>()
        return urls.compactMap { url -> VolumeInfo? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.volumeIsBrowsable != false,
                  let total = values.volumeTotalCapacity, total > 0 else { return nil }
            let path = url.path
            guard seen.insert(path).inserted else { return nil }
            // `ForImportantUsage` includes purgeable space, which is what Finder shows.
            let available = values.volumeAvailableCapacityForImportantUsage.map { UInt64($0) }
                ?? UInt64(values.volumeAvailableCapacity ?? 0)
            return VolumeInfo(name: values.volumeName ?? url.lastPathComponent,
                              path: path,
                              total: UInt64(total),
                              available: min(available, UInt64(total)),
                              isInternal: values.volumeIsInternal ?? true,
                              isRemovable: values.volumeIsRemovable ?? false,
                              format: values.volumeLocalizedFormatDescription ?? "—")
        }
        .sorted { ($0.isInternal ? 0 : 1, $0.name) < ($1.isInternal ? 0 : 1, $1.name) }
    }

    /// Aggregate block-device throughput read from every `IOBlockStorageDriver`.
    func io() -> DiskIOSample {
        var sample = DiskIOSample()
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOBlockStorageDriver"),
                                           &iterator) == KERN_SUCCESS else { return sample }
        defer { IOObjectRelease(iterator) }

        var totalRead: UInt64 = 0
        var totalWritten: UInt64 = 0
        while case let drive = IOIteratorNext(iterator), drive != 0 {
            defer { IOObjectRelease(drive) }
            var properties: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(drive, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dictionary = properties?.takeRetainedValue() as? [String: Any],
                  let statistics = dictionary["Statistics"] as? [String: Any] else { continue }
            totalRead += (statistics["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            totalWritten += (statistics["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
        }

        sample.totalRead = totalRead
        sample.totalWritten = totalWritten

        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - previousTimestamp
        if previousTimestamp > 0, elapsed > 0 {
            sample.readBytesPerSecond = max(0, Double(totalRead &- previousRead) / elapsed)
            sample.writeBytesPerSecond = max(0, Double(totalWritten &- previousWritten) / elapsed)
        }
        previousRead = totalRead
        previousWritten = totalWritten
        previousTimestamp = now
        return sample
    }
}
