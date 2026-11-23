import Foundation
import IOKit
import IOKit.ps

public struct PowerError: LocalizedError {
    public let text: String
    public init(text: String) { self.text = text }
    public var errorDescription: String? { text }
}

/// Read-only lid/power access for the compatibility app and root LaunchDaemon.
public final class PowerDriver {
    public let root: io_service_t
    private var connection: io_connect_t = 0
    public init() throws {
        root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { throw PowerError(text: "找不到合盖控制接口") }
        let result = IOServiceOpen(root, mach_task_self_, 0, &connection)
        guard result == KERN_SUCCESS else {
            IOObjectRelease(root)
            throw PowerError(text: "无法打开合盖接口：\(Self.hex(result))")
        }
    }
    deinit {
        IOServiceClose(connection)
        IOObjectRelease(root)
    }
    public static func hex(_ result: IOReturn) -> String {
        String(format: "0x%08x", UInt32(bitPattern: result))
    }
    public func bool(_ key: String) -> Bool? {
        guard let value = IORegistryEntryCreateCFProperty(root, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
              CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return (value as! NSNumber).boolValue
    }
}

public struct BatteryReading {
    public var percent: Int?
    public var onBattery: Bool
}

public func batteryReading() -> BatteryReading {
    guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
        return BatteryReading(percent: nil, onBattery: true)
    }
    let onBattery = (IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?) == kIOPSBatteryPowerValue
    let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] ?? []
    for source in sources {
        guard let description = IOPSGetPowerSourceDescription(info, source)?.takeRetainedValue() as? [String: Any],
              description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
              let current = description[kIOPSCurrentCapacityKey] as? Int,
              let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
        return BatteryReading(percent: Int(Double(current) / Double(maximum) * 100), onBattery: onBattery)
    }
    return BatteryReading(percent: nil, onBattery: onBattery)
}
