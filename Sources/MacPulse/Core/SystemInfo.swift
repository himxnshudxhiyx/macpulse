import Darwin
import Foundation
import IOKit

struct SystemInfo {
    var modelIdentifier = "—"
    var marketingName = "—"
    var chip = "—"
    var totalCores = 0
    var performanceCores = 0
    var efficiencyCores = 0
    var gpuCores: Int?
    var physicalMemory: UInt64 = 0
    var memoryType = "—"
    var osName = "macOS"
    var osVersion = "—"
    var buildVersion = "—"
    var kernelVersion = "—"
    var hostName = "—"
    var userName = NSUserName()
    var bootTime = Date()
    var architecture = "—"
    var isAppleSilicon = false

    var uptime: TimeInterval { Date().timeIntervalSince(bootTime) }

    static func load() -> SystemInfo {
        var info = SystemInfo()
        info.modelIdentifier = Sysctl.string("hw.model") ?? "—"
        info.chip = Sysctl.string("machdep.cpu.brand_string") ?? "—"
        info.totalCores = Sysctl.int("hw.logicalcpu") ?? 0
        info.performanceCores = Sysctl.int("hw.perflevel0.logicalcpu") ?? 0
        info.efficiencyCores = Sysctl.int("hw.perflevel1.logicalcpu") ?? 0
        info.physicalMemory = Sysctl.integer("hw.memsize") ?? 0
        info.osVersion = Sysctl.string("kern.osproductversion") ?? "—"
        info.buildVersion = Sysctl.string("kern.osversion") ?? "—"
        info.kernelVersion = Sysctl.string("kern.version")?.components(separatedBy: ":").first ?? "—"
        info.hostName = Sysctl.string("kern.hostname") ?? ProcessInfo.processInfo.hostName
        info.isAppleSilicon = (Sysctl.int("hw.optional.arm64") ?? 0) == 1
        info.architecture = info.isAppleSilicon ? "arm64 (Apple silicon)" : "x86_64 (Intel)"
        info.marketingName = marketingName(for: info.modelIdentifier)
        info.gpuCores = gpuCoreCount()

        if let boot = Sysctl.raw("kern.boottime", as: timeval.self) {
            info.bootTime = Date(timeIntervalSince1970: Double(boot.tv_sec) + Double(boot.tv_usec) / 1_000_000)
        }
        return info
    }

    /// The marketing name ("MacBook Air (13-inch, M4, 2025)") lives on the
    /// `IODeviceTree:/product` node. Older machines keep it on the platform
    /// expert instead, and anything else falls back to the model identifier.
    private static func marketingName(for identifier: String) -> String {
        if let name = registryString(path: "IODeviceTree:/product", key: "product-name") { return name }
        if let name = registryString(service: "IOPlatformExpertDevice", key: "product-name") { return name }
        return identifier
    }

    private static func registryString(path: String, key: String) -> String? {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, path)
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        return decode(IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue())
    }

    private static func registryString(service: String, key: String) -> String? {
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(service))
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        return decode(IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue())
    }

    /// These properties arrive as null-terminated C strings wrapped in `Data`.
    private static func decode(_ value: CFTypeRef?) -> String? {
        if let text = value as? String, !text.isEmpty { return text }
        guard let data = value as? Data,
              let text = String(data: data, encoding: .utf8)?
                  .trimmingCharacters(in: CharacterSet(charactersIn: "\0").union(.whitespacesAndNewlines)),
              !text.isEmpty else { return nil }
        return text
    }

    private static func gpuCoreCount() -> Int? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("AGXAccelerator"),
                                           &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            if let value = IORegistryEntryCreateCFProperty(entry, "gpu-core-count" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? NSNumber {
                return value.intValue
            }
        }
        return nil
    }
}
