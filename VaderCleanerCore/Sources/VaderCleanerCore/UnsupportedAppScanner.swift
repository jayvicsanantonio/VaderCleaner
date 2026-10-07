// UnsupportedAppScanner.swift
// Reads each installed app's Mach-O executable to find its CPU architectures and flags the apps with no slice the current macOS can run (no arm64 / x86_64).

import Foundation
import os.log

/// Mach-O CPU type constants (subset). Values match `<mach/machine.h>`:
/// the 64-bit ABI bit (`0x0100_0000`) OR'd with the base type.
enum MachOCPUType {
    static let x86_64: UInt32 = 0x0100_0007
    static let arm64: UInt32  = 0x0100_000C
}

/// Decides whether a set of executable architectures is runnable on the
/// current macOS. `arm64` runs natively on Apple Silicon; `x86_64` runs
/// natively on Intel and under Rosetta 2 on Apple Silicon. Anything with only
/// 32-bit Intel (`i386`) or PowerPC slices can't launch on a modern macOS.
enum UnsupportedAppClassifier {

    /// Architectures the current macOS can run.
    static let runnableCPUTypes: Set<UInt32> = [MachOCPUType.x86_64, MachOCPUType.arm64]

    /// True when the executable has architectures *and none of them* is
    /// runnable. An empty/unknown list returns `false` — we never flag an app
    /// we couldn't actually read, biasing toward false negatives so a parse
    /// miss never offers a working app for removal.
    static func isUnsupported(cpuTypes: [UInt32]) -> Bool {
        guard !cpuTypes.isEmpty else { return false }
        return Set(cpuTypes).isDisjoint(with: runnableCPUTypes)
    }
}

/// Parses the CPU architectures out of a Mach-O or universal ("fat") binary
/// header. Pure byte parsing with no I/O, so it is exhaustively unit-tested
/// against synthetic header fixtures.
enum MachOHeaderReader {

    private static let fatMagic: UInt32    = 0xCAFE_BABE
    private static let fatMagic64: UInt32  = 0xCAFE_BABF
    private static let machMagic: UInt32   = 0xFEED_FACE
    private static let machMagic64: UInt32 = 0xFEED_FACF

    /// Returns the CPU types declared in the header, or `nil` when `data` is
    /// not a recognizable Mach-O / universal binary.
    static func cpuTypes(in data: Data) -> [UInt32]? {
        let bytes = [UInt8](data)
        guard bytes.count >= 8 else { return nil }

        func u32(_ offset: Int, bigEndian: Bool) -> UInt32? {
            guard offset >= 0, offset + 4 <= bytes.count else { return nil }
            let value = UInt32(bytes[offset]) << 24
                | UInt32(bytes[offset + 1]) << 16
                | UInt32(bytes[offset + 2]) << 8
                | UInt32(bytes[offset + 3])
            return bigEndian ? value : value.byteSwapped
        }

        // Universal binaries store their header big-endian on disk.
        let beMagic = u32(0, bigEndian: true)
        if beMagic == fatMagic || beMagic == fatMagic64 {
            guard let nfat = u32(4, bigEndian: true), nfat <= 64 else { return nil }
            let is64 = beMagic == fatMagic64
            // fat_arch is 20 bytes, fat_arch_64 is 32 bytes; `cputype` is the
            // first 4 bytes of either, so the entry stride is all that differs.
            let entryStride = is64 ? 32 : 20
            var types: [UInt32] = []
            var offset = 8
            for _ in 0..<nfat {
                guard let cpuType = u32(offset, bigEndian: true) else { return nil }
                types.append(cpuType)
                offset += entryStride
            }
            return types
        }

        // Thin Mach-O: the magic's byte order tells us how to read `cputype`
        // (the field immediately after the magic).
        if let le = u32(0, bigEndian: false), le == machMagic || le == machMagic64 {
            guard let cpuType = u32(4, bigEndian: false) else { return nil }
            return [cpuType]
        }
        if beMagic == machMagic || beMagic == machMagic64 {
            guard let cpuType = u32(4, bigEndian: true) else { return nil }
            return [cpuType]
        }
        return nil
    }
}

/// Test seam between `ApplicationsViewModel` and the on-disk Mach-O parsing.
protocol UnsupportedAppScanning: Sendable {
    func scan(apps: [AppInfo]) async -> [UnsupportedApp]
}

/// Production scanner — resolves each app's main executable, reads its Mach-O
/// header, and flags the ones with no runnable architecture.
struct DefaultUnsupportedAppScanner: UnsupportedAppScanning {

    /// Resolves the CPU types of an app's main executable, or `nil` when it
    /// can't be read. Injected so tests drive classification without real
    /// binaries.
    private let cpuTypesForApp: @Sendable (AppInfo) -> [UInt32]?
    private let log = Logger(subsystem: "com.personal.VaderCleaner",
                             category: "UnsupportedAppScanner")

    init(cpuTypesForApp: @escaping @Sendable (AppInfo) -> [UInt32]? = DefaultUnsupportedAppScanner.readCPUTypes) {
        self.cpuTypesForApp = cpuTypesForApp
    }

    func scan(apps: [AppInfo]) async -> [UnsupportedApp] {
        let provider = cpuTypesForApp
        let log = log
        return await Task.detached(priority: .userInitiated) {
            let unsupported = apps.compactMap { app -> UnsupportedApp? in
                guard let types = provider(app),
                      UnsupportedAppClassifier.isUnsupported(cpuTypes: types) else {
                    return nil
                }
                return UnsupportedApp(app: app, reason: .incompatibleArchitecture)
            }
            log.debug("Unsupported-app scan flagged \(unsupported.count, privacy: .public) app(s)")
            return unsupported
        }.value
    }

    /// Default provider: read the first 64 KB of the app's main executable
    /// (enough for the fat header + its arch table, or a thin Mach-O header)
    /// and parse out the architectures. Returns `nil` on any failure so the
    /// classifier treats it as "unknown — don't flag".
    static func readCPUTypes(_ app: AppInfo) -> [UInt32]? {
        let contents = app.bundleURL.appendingPathComponent("Contents", isDirectory: true)
        let executableName = executableName(forBundleAt: app.bundleURL)
            ?? app.bundleURL.deletingPathExtension().lastPathComponent
        let executableURL = contents
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent(executableName)

        guard let handle = try? FileHandle(forReadingFrom: executableURL) else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 64 * 1024)) ?? Data()
        return MachOHeaderReader.cpuTypes(in: data)
    }

    /// Reads `CFBundleExecutable` from the bundle's `Info.plist`.
    private static func executableName(forBundleAt bundleURL: URL) -> String? {
        let infoPlist = bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: infoPlist),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let name = plist["CFBundleExecutable"] as? String,
              !name.isEmpty else {
            return nil
        }
        return name
    }
}
