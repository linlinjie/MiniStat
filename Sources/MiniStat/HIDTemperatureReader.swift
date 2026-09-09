import Darwin
import Foundation

final class HIDTemperatureReader {
    private struct SensorReading {
        let name: String
        let value: Double
    }

    private var system: UnsafeMutableRawPointer?
    private var services: CFArray?

    init() {
        guard let create = HIDAPI.create,
              let setMatching = HIDAPI.setMatching,
              let copyServices = HIDAPI.copyServices,
              let system = create(kCFAllocatorDefault) else {
            return
        }

        setMatching(system, Self.temperatureMatchingDictionary)
        guard let services = copyServices(system)?.takeRetainedValue() else {
            Self.release(system)
            return
        }
        self.system = system
        self.services = services
    }

    deinit {
        if let system {
            Self.release(system)
        }
    }

    func averageM1CPUTemperature() -> Double? {
        let readings = readSensors()
        let coreValues = readings.compactMap { reading -> Double? in
            let isCPUCore = reading.name.hasPrefix("pACC MTR Temp")
                || reading.name.hasPrefix("eACC MTR Temp")
                || reading.name.contains("CPU")
            guard isCPUCore else { return nil }
            return MetricMath.validTemperature(reading.value)
        }

        guard !coreValues.isEmpty else { return nil }
        return coreValues.reduce(0, +) / Double(coreValues.count)
    }

    private func readSensors() -> [SensorReading] {
        guard let services,
              let copyProperty = HIDAPI.copyProperty,
              let copyEvent = HIDAPI.copyEvent,
              let getFloatValue = HIDAPI.getFloatValue else {
            return []
        }

        let temperatureEventType: Int64 = 15
        let temperatureField = Int32(temperatureEventType << 16)
        var readings: [SensorReading] = []

        for index in 0..<CFArrayGetCount(services) {
            guard let serviceValue = CFArrayGetValueAtIndex(services, index) else { continue }
            let service = UnsafeMutableRawPointer(mutating: serviceValue)

            let name: String
            if let property = copyProperty(service, "Product" as CFString)?.takeRetainedValue() as? String {
                name = property
            } else {
                continue
            }

            guard let event = copyEvent(service, temperatureEventType, 0, 0) else { continue }
            let value = getFloatValue(event, temperatureField)
            Self.release(event)
            readings.append(SensorReading(name: name, value: value))
        }
        return readings
    }

    private static func release(_ pointer: UnsafeMutableRawPointer) {
        Unmanaged<CFTypeRef>.fromOpaque(pointer).release()
    }

    private static let temperatureMatchingDictionary: CFDictionary = {
        var usagePage: Int32 = 0xff00
        var usage: Int32 = 5
        let pageNumber = CFNumberCreate(kCFAllocatorDefault, .sInt32Type, &usagePage)
        let usageNumber = CFNumberCreate(kCFAllocatorDefault, .sInt32Type, &usage)
        return [
            "PrimaryUsagePage" as CFString: pageNumber as Any,
            "PrimaryUsage" as CFString: usageNumber as Any
        ] as CFDictionary
    }()
}

private enum HIDAPI {
    typealias Create = @convention(c) (CFAllocator?) -> UnsafeMutableRawPointer?
    typealias SetMatching = @convention(c) (UnsafeMutableRawPointer, CFDictionary) -> Void
    typealias CopyServices = @convention(c) (UnsafeMutableRawPointer) -> Unmanaged<CFArray>?
    typealias CopyProperty = @convention(c) (UnsafeMutableRawPointer, CFString) -> Unmanaged<AnyObject>?
    typealias CopyEvent = @convention(c) (UnsafeMutableRawPointer, Int64, Int32, Int64) -> UnsafeMutableRawPointer?
    typealias GetFloatValue = @convention(c) (UnsafeMutableRawPointer, Int32) -> Double

    private static let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)

    static let create: Create? = load("IOHIDEventSystemClientCreate")
    static let setMatching: SetMatching? = load("IOHIDEventSystemClientSetMatching")
    static let copyServices: CopyServices? = load("IOHIDEventSystemClientCopyServices")
    static let copyProperty: CopyProperty? = load("IOHIDServiceClientCopyProperty")
    static let copyEvent: CopyEvent? = load("IOHIDServiceClientCopyEvent")
    static let getFloatValue: GetFloatValue? = load("IOHIDEventGetFloatValue")

    private static func load<T>(_ symbol: String) -> T? {
        guard let handle, let address = dlsym(handle, symbol) else { return nil }
        return unsafeBitCast(address, to: T.self)
    }
}
