import Foundation
import IOKit

struct SensorReading: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let celsius: Double
}

struct TemperatureSample {
    var soc: Double?          // average across the SoC die sensors
    var socPeak: Double?      // hottest die sensor
    var battery: Double?
    var storage: Double?
    var sensors: [SensorReading] = []

    var isAvailable: Bool { soc != nil || battery != nil }
}

/// Creates the sensor client on first use and keeps every call on one thread.
/// `IOHIDEventSystemClient` is not thread-safe, so it is built and read on the
/// sampler queue and nowhere else.
final class TemperatureProvider: @unchecked Sendable {
    private var monitor: TemperatureMonitor?
    private var attempted = false

    /// Call only from the sampler queue.
    func sample() -> TemperatureSample {
        if !attempted {
            attempted = true
            monitor = TemperatureMonitor()
        }
        return monitor?.sample() ?? TemperatureSample()
    }
}

/// Apple silicon exposes its thermal sensors through the HID event system
/// rather than the SMC, and the functions that read them are not in any public
/// header. They are resolved at runtime, so a future macOS that drops them
/// degrades to "no reading" instead of failing to launch.
final class TemperatureMonitor: @unchecked Sendable {
    private typealias ClientCreate = @convention(c) (CFAllocator?) -> Unmanaged<CFTypeRef>?
    private typealias SetMatching = @convention(c) (CFTypeRef, CFDictionary) -> Void
    private typealias CopyServices = @convention(c) (CFTypeRef) -> Unmanaged<CFArray>?
    private typealias CopyProperty = @convention(c) (CFTypeRef, CFString) -> Unmanaged<CFTypeRef>?
    private typealias CopyEvent = @convention(c) (CFTypeRef, Int64, Int32, Int64) -> Unmanaged<CFTypeRef>?
    private typealias GetFloatValue = @convention(c) (CFTypeRef, Int32) -> Double

    /// `kIOHIDEventTypeTemperature`, and the field index derived from it.
    private static let temperatureEvent: Int64 = 15
    private static let temperatureField = Int32(temperatureEvent << 16)

    private let copyProperty: CopyProperty
    private let copyEvent: CopyEvent
    private let floatValue: GetFloatValue
    /// The service refs stay valid only while their parent client is alive, so
    /// the client is held for the lifetime of this object. Dropping it and then
    /// reading a service aborts the process inside IOKit's own locking.
    private let client: CFTypeRef
    private let services: [CFTypeRef]
    private var names: [ObjectIdentifier: String] = [:]

    init?() {
        func symbol<T>(_ name: String, _ type: T.Type) -> T? {
            guard let pointer = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }
            return unsafeBitCast(pointer, to: T.self)
        }
        guard let create = symbol("IOHIDEventSystemClientCreate", ClientCreate.self),
              let setMatching = symbol("IOHIDEventSystemClientSetMatching", SetMatching.self),
              let copyServices = symbol("IOHIDEventSystemClientCopyServices", CopyServices.self),
              let copyProperty = symbol("IOHIDServiceClientCopyProperty", CopyProperty.self),
              let copyEvent = symbol("IOHIDServiceClientCopyEvent", CopyEvent.self),
              let floatValue = symbol("IOHIDEventGetFloatValue", GetFloatValue.self),
              let client = create(kCFAllocatorDefault)?.takeRetainedValue() else { return nil }

        // Usage page 0xff00 / usage 5 is Apple's temperature sensor family.
        setMatching(client, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        guard let matched = copyServices(client)?.takeRetainedValue() as? [CFTypeRef], !matched.isEmpty else { return nil }

        self.copyProperty = copyProperty
        self.copyEvent = copyEvent
        self.floatValue = floatValue
        self.client = client
        self.services = matched
    }

    func sample() -> TemperatureSample {
        var result = TemperatureSample()
        var dieTemperatures: [Double] = []
        var batteryTemperatures: [Double] = []
        var storageTemperatures: [Double] = []
        var readings: [SensorReading] = []

        for service in services {
            guard let event = copyEvent(service, Self.temperatureEvent, 0, 0)?.takeRetainedValue() else { continue }
            let celsius = floatValue(event, Self.temperatureField)
            // Disconnected sensors report 0; anything past 150 °C is a bad read.
            guard celsius > 0, celsius < 150 else { continue }
            let name = name(of: service)

            // `tcal` is a fixed calibration reference, not a measurement.
            guard !name.hasSuffix("tcal") else { continue }

            readings.append(SensorReading(name: name, celsius: celsius))
            let lowercased = name.lowercased()
            if lowercased.contains("tdie") {
                dieTemperatures.append(celsius)
            } else if lowercased.contains("battery") {
                batteryTemperatures.append(celsius)
            } else if lowercased.contains("nand") || lowercased.contains("ssd") {
                storageTemperatures.append(celsius)
            }
        }

        if !dieTemperatures.isEmpty {
            result.soc = dieTemperatures.reduce(0, +) / Double(dieTemperatures.count)
            result.socPeak = dieTemperatures.max()
        }
        result.battery = batteryTemperatures.max()
        result.storage = storageTemperatures.max()
        result.sensors = readings.sorted { $0.celsius > $1.celsius }
        return result
    }

    /// Sensor names never change, so each service is only asked once.
    private func name(of service: CFTypeRef) -> String {
        let key = ObjectIdentifier(service as AnyObject)
        if let cached = names[key] { return cached }
        let resolved = copyProperty(service, "Product" as CFString)?.takeRetainedValue() as? String ?? "Sensor"
        names[key] = resolved
        return resolved
    }
}
