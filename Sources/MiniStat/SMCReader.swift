import Foundation
import IOKit

private struct SMCVersion {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
}

private struct SMCPLimitData {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
}

private struct SMCKeyInfo {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
}

private typealias SMCBytes = (
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
)

private struct SMCParam {
    var key: UInt32 = 0
    var version = SMCVersion()
    var pLimitData = SMCPLimitData()
    var keyInfo = SMCKeyInfo()
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes = (
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0
    )
}

final class SMCReader {
    // M1-family CPU temperature keys. Missing keys are expected on the base M1.
    private static let m1CPUKeys = [
        "Tp09", "Tp0T",
        "Tp01", "Tp05", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0X", "Tp0b"
    ]

    private let selector: UInt32 = 2
    private var connection: io_connect_t = 0

    init() {
        guard MemoryLayout<SMCParam>.stride == 80,
              let matching = IOServiceMatching("AppleSMC") else { return }

        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }

        var openedConnection: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &openedConnection) == kIOReturnSuccess else {
            return
        }
        connection = openedConnection
    }

    deinit {
        if connection != 0 {
            IOServiceClose(connection)
        }
    }

    func averageM1CPUTemperature() -> Double? {
        guard connection != 0 else { return nil }
        let values = Self.m1CPUKeys.compactMap(readTemperature(forKey:))
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private func readTemperature(forKey key: String) -> Double? {
        guard let keyCode = Self.fourCharacterCode(key) else { return nil }

        var keyInfoInput = SMCParam()
        keyInfoInput.key = keyCode
        keyInfoInput.data8 = 9 // kSMCGetKeyInfo
        guard let keyInfoOutput = call(&keyInfoInput),
              keyInfoOutput.result == 0,
              keyInfoOutput.keyInfo.dataSize > 0,
              keyInfoOutput.keyInfo.dataSize <= 32 else {
            return nil
        }

        var readInput = SMCParam()
        readInput.key = keyCode
        readInput.keyInfo.dataSize = keyInfoOutput.keyInfo.dataSize
        readInput.data8 = 5 // kSMCReadKey
        guard var readOutput = call(&readInput), readOutput.result == 0 else { return nil }

        let count = Int(keyInfoOutput.keyInfo.dataSize)
        let bytes = withUnsafeBytes(of: &readOutput.bytes) { rawBuffer in
            Array(rawBuffer.prefix(count))
        }
        let type = Self.fourCharacterString(keyInfoOutput.keyInfo.dataType)
        return MetricMath.validTemperature(Self.decode(bytes: bytes, type: type))
    }

    private func call(_ input: inout SMCParam) -> SMCParam? {
        var output = SMCParam()
        var outputSize = MemoryLayout<SMCParam>.stride
        let result = IOConnectCallStructMethod(
            connection,
            selector,
            &input,
            MemoryLayout<SMCParam>.stride,
            &output,
            &outputSize
        )
        guard result == kIOReturnSuccess, outputSize == MemoryLayout<SMCParam>.stride else {
            return nil
        }
        return output
    }

    private static func decode(bytes: [UInt8], type: String) -> Double? {
        switch type {
        case "sp78" where bytes.count >= 2:
            let bits = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
            return Double(Int16(bitPattern: bits)) / 256
        case "fp88" where bytes.count >= 2:
            let bits = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
            return Double(bits) / 256
        case "flt " where bytes.count >= 4:
            let bits = UInt32(bytes[0])
                | UInt32(bytes[1]) << 8
                | UInt32(bytes[2]) << 16
                | UInt32(bytes[3]) << 24
            return Double(Float(bitPattern: bits))
        case "ui8 " where !bytes.isEmpty:
            return Double(bytes[0])
        case "ui16" where bytes.count >= 2:
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        default:
            return nil
        }
    }

    private static func fourCharacterCode(_ string: String) -> UInt32? {
        let bytes = Array(string.utf8)
        guard bytes.count == 4 else { return nil }
        return bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    private static func fourCharacterString(_ value: UInt32) -> String {
        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff)
        ]
        return String(bytes: bytes, encoding: .ascii) ?? ""
    }
}
