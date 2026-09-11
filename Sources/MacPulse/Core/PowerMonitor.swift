import Foundation
import IOKit
import IOKit.ps

struct PowerSample {
    var hasBattery = false
    var charge: Double = 0
    var isCharging = false
    var isOnACPower = true
    var timeToEmptyMinutes: Int?
    var timeToFullMinutes: Int?
    var cycleCount: Int?
    var designCapacity: Int?
    var maxCapacity: Int?
    var temperatureCelsius: Double?
    var powerSourceName = "AC Power"
    var thermalState: ProcessInfo.ThermalState = .nominal

    /// Apple's "Battery Condition" percentage: current full-charge capacity
    /// relative to the capacity the cell shipped with.
    var healthFraction: Double? {
        guard let design = designCapacity, design > 0, let max = maxCapacity else { return nil }
        return min(1, Double(max) / Double(design))
    }
}

final class PowerMonitor: @unchecked Sendable {
    func sample() -> PowerSample {
        var sample = PowerSample()
        sample.thermalState = ProcessInfo.processInfo.thermalState

        if let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] {
            sample.powerSourceName = (IOPSGetProvidingPowerSourceType(blob)?.takeRetainedValue() as String?) ?? "AC Power"
            sample.isOnACPower = sample.powerSourceName != kIOPMBatteryPowerKey

            for source in sources {
                guard let description = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                      (description[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
                sample.hasBattery = true
                let current = (description[kIOPSCurrentCapacityKey] as? Int) ?? 0
                let maximum = (description[kIOPSMaxCapacityKey] as? Int) ?? 100
                sample.charge = maximum > 0 ? Double(current) / Double(maximum) : 0
                sample.isCharging = (description[kIOPSIsChargingKey] as? Bool) ?? false
                if let minutes = description[kIOPSTimeToEmptyKey] as? Int, minutes > 0 { sample.timeToEmptyMinutes = minutes }
                if let minutes = description[kIOPSTimeToFullChargeKey] as? Int, minutes > 0 { sample.timeToFullMinutes = minutes }
            }
        }

        mergeSmartBattery(into: &sample)
        return sample
    }

    /// `AppleSmartBattery` carries the cycle count, design capacity and cell
    /// temperature that the power-source API does not expose.
    private func mergeSmartBattery(into sample: inout PowerSample) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }

        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dictionary = properties?.takeRetainedValue() as? [String: Any] else { return }

        sample.hasBattery = true
        sample.cycleCount = dictionary["CycleCount"] as? Int
        sample.designCapacity = dictionary["DesignCapacity"] as? Int
        sample.maxCapacity = (dictionary["AppleRawMaxCapacity"] as? Int) ?? (dictionary["MaxCapacity"] as? Int)
        if let raw = dictionary["Temperature"] as? Int {
            sample.temperatureCelsius = Double(raw) / 100.0
        }
    }
}

extension ProcessInfo.ThermalState {
    var label: String {
        switch self {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }
}
