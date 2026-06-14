// SMCReader.swift
// Best-effort AppleSMC reader for CPU temperature. SMC keys are undocumented and chip-specific, so every read is defensive and returns nil rather than a guess.

import Foundation
import IOKit

/// Reads temperature sensors from the Apple System Management Controller.
///
/// SMC keys, data types, and which sensors map to "the CPU" are all
/// undocumented and vary by chip generation, so this is deliberately
/// conservative: it enumerates the available keys, averages the per-core die
/// sensors on Apple Silicon (`Tp…`), falls back to the classic Intel CPU keys,
/// and returns `nil` whenever nothing plausible is found. Callers must treat a
/// `nil` (or a hidden tile) as the normal "unavailable" case.
final class SMCReader {

    private var connection: io_connect_t = 0

    /// Opens a user client to `AppleSMC`. Fails (returns `nil`) when the
    /// service is missing or the connection can't be opened.
    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == kIOReturnSuccess else {
            return nil
        }
    }

    deinit {
        if connection != 0 { IOServiceClose(connection) }
    }

    /// Best-effort current CPU temperature in degrees Celsius, or `nil` when no
    /// plausible sensor is readable on this hardware.
    func cpuTemperatureCelsius() -> Double? {
        // Apple Silicon exposes many per-core die sensors keyed `Tp…`; average
        // the plausible ones for a representative figure.
        let dieTemps = appleSiliconDieTemperatures()
        if !dieTemps.isEmpty {
            return dieTemps.reduce(0, +) / Double(dieTemps.count)
        }
        // Intel fallback: CPU die / proximity.
        for key in ["TC0D", "TC0P", "TC0E", "TC0F"] {
            if let value = temperature(forKey: key) { return value }
        }
        return nil
    }

    /// Reads every `Tp…`-prefixed sensor (Apple Silicon performance/efficiency
    /// core die temps) that returns a plausible value.
    private func appleSiliconDieTemperatures() -> [Double] {
        guard let count = keyCount() else { return [] }
        var temps: [Double] = []
        for index in 0..<count {
            guard let key = key(atIndex: index) else { continue }
            // Core die sensors start with "Tp" (perf) or "Te"/"Tg" on some
            // chips; restrict to "Tp" which is the most consistent CPU proxy.
            guard key.hasPrefix("Tp") else { continue }
            if let value = temperature(forKey: key) { temps.append(value) }
        }
        return temps
    }

    /// Reads a single temperature key, decoding its SMC data type. Returns
    /// `nil` when the key is absent, the type is unsupported, or the value is
    /// outside a plausible range.
    private func temperature(forKey key: String) -> Double? {
        guard let (info, bytes) = readKey(key) else { return nil }
        guard let celsius = Self.decodeTemperature(dataType: info.dataType, bytes: bytes) else { return nil }
        guard celsius > 0, celsius < 120 else { return nil }
        return celsius
    }

    // MARK: - Pure decoding

    /// Decodes a temperature value from raw SMC bytes by data type. Supports
    /// `sp78` (Intel signed 7.8 fixed point) and `flt ` (Apple Silicon IEEE
    /// float, little-endian). Returns `nil` for unsupported types or short
    /// buffers.
    static func decodeTemperature(dataType: UInt32, bytes: [UInt8]) -> Double? {
        switch dataType {
        case fourCharCode("sp78"):
            guard bytes.count >= 2 else { return nil }
            let raw = Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
            return Double(raw) / 256.0
        case fourCharCode("flt "):
            guard bytes.count >= 4 else { return nil }
            let bits = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            return Double(Float(bitPattern: bits))
        default:
            return nil
        }
    }

    /// Packs a 4-character SMC key/type into its big-endian `UInt32` code.
    static func fourCharCode(_ string: String) -> UInt32 {
        let chars = Array(string.utf8)
        guard chars.count == 4 else { return 0 }
        return UInt32(chars[0]) << 24 | UInt32(chars[1]) << 16 | UInt32(chars[2]) << 8 | UInt32(chars[3])
    }

    // MARK: - IOKit plumbing

    private func keyCount() -> UInt32? {
        guard let (info, bytes) = readKey("#KEY"), info.dataSize >= 4, bytes.count >= 4 else { return nil }
        return UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
    }

    private func key(atIndex index: UInt32) -> String? {
        var input = SMCKeyData()
        input.data8 = SMCSelector.readIndex
        input.data32 = index
        guard let output = call(input), output.result == 0 else { return nil }
        return Self.string(fromKeyCode: output.key)
    }

    /// Reads a key's info (data type/size) then its raw value bytes.
    private func readKey(_ key: String) -> (info: SMCKeyDataKeyInfo, bytes: [UInt8])? {
        let keyCode = Self.fourCharCode(key)

        var infoInput = SMCKeyData()
        infoInput.key = keyCode
        infoInput.data8 = SMCSelector.readKeyInfo
        guard let infoOutput = call(infoInput), infoOutput.result == 0 else { return nil }
        let info = infoOutput.keyInfo

        var readInput = SMCKeyData()
        readInput.key = keyCode
        readInput.keyInfo = info
        readInput.data8 = SMCSelector.readBytes
        guard let readOutput = call(readInput), readOutput.result == 0 else { return nil }

        let size = Int(min(info.dataSize, 32))
        let bytes = Self.bytesArray(readOutput.bytes, count: size)
        return (info, bytes)
    }

    private func call(_ input: SMCKeyData) -> SMCKeyData? {
        var input = input
        var output = SMCKeyData()
        var outputSize = MemoryLayout<SMCKeyData>.stride
        let result = IOConnectCallStructMethod(
            connection,
            SMCSelector.kernelIndex,
            &input,
            MemoryLayout<SMCKeyData>.stride,
            &output,
            &outputSize
        )
        return result == kIOReturnSuccess ? output : nil
    }

    /// Decodes a 4-byte SMC key code back into its string form.
    private static func string(fromKeyCode code: UInt32) -> String {
        let chars = [
            UInt8((code >> 24) & 0xff),
            UInt8((code >> 16) & 0xff),
            UInt8((code >> 8) & 0xff),
            UInt8(code & 0xff)
        ]
        return String(decoding: chars, as: UTF8.self)
    }

    /// Copies the fixed 32-byte SMC tuple into a `[UInt8]` of `count` bytes.
    private static func bytesArray(_ tuple: SMCBytes32, count: Int) -> [UInt8] {
        var values = tuple
        return withUnsafeBytes(of: &values) { raw in
            Array(raw.prefix(count)).map { $0 }
        }
    }
}

// MARK: - SMC C-compatible structures

/// SMC user-client call selectors and read commands.
private enum SMCSelector {
    static let kernelIndex: UInt32 = 2
    static let readBytes: UInt8 = 5
    static let readIndex: UInt8 = 8
    static let readKeyInfo: UInt8 = 9
}

/// The 32-byte value buffer the SMC returns, as a fixed-size tuple matching the
/// kernel struct's array.
typealias SMCBytes32 = (
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
)

struct SMCKeyDataVersion {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
}

struct SMCKeyDataPLimit {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
}

struct SMCKeyDataKeyInfo {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
}

/// Mirror of the kernel's `SMCKeyData_t`. Field order and types must match the
/// SMC user client exactly.
struct SMCKeyData {
    var key: UInt32 = 0
    var vers = SMCKeyDataVersion()
    var pLimitData = SMCKeyDataPLimit()
    var keyInfo = SMCKeyDataKeyInfo()
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes32 = (
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0
    )
}
