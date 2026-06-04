// MachOHeaderReaderTests.swift
// Drives MachOHeaderReader against synthetic Mach-O / universal header bytes and pins UnsupportedAppClassifier's runnable-architecture rule — fully hermetic, no real binaries.

import XCTest
@testable import VaderCleaner

final class MachOHeaderReaderTests: XCTestCase {

    // MARK: - Byte builders

    private func be32(_ v: UInt32) -> [UInt8] {
        [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]
    }
    private func le32(_ v: UInt32) -> [UInt8] { be32(v).reversed() }
    private let pad16 = [UInt8](repeating: 0, count: 16)
    private let pad28 = [UInt8](repeating: 0, count: 28)

    private let i386: UInt32 = 7
    private let powerpc: UInt32 = 18

    // MARK: - Thin Mach-O

    func test_thinLittleEndian_arm64() {
        // MH_MAGIC_64 (0xFEEDFACF) stored little-endian, then arm64 cputype.
        let data = Data(le32(0xFEED_FACF) + le32(MachOCPUType.arm64))
        XCTAssertEqual(MachOHeaderReader.cpuTypes(in: data), [MachOCPUType.arm64])
    }

    func test_thinLittleEndian_x86_64() {
        let data = Data(le32(0xFEED_FACF) + le32(MachOCPUType.x86_64))
        XCTAssertEqual(MachOHeaderReader.cpuTypes(in: data), [MachOCPUType.x86_64])
    }

    func test_thinLittleEndian_i386_32bit() {
        // MH_MAGIC (0xFEEDFACE) — 32-bit header — with the i386 cputype.
        let data = Data(le32(0xFEED_FACE) + le32(i386))
        XCTAssertEqual(MachOHeaderReader.cpuTypes(in: data), [i386])
    }

    // MARK: - Universal (fat) binaries

    func test_fatBigEndian_x86_64_and_arm64() {
        let data = Data(
            be32(0xCAFE_BABE) + be32(2)
            + be32(MachOCPUType.x86_64) + pad16
            + be32(MachOCPUType.arm64) + pad16
        )
        XCTAssertEqual(
            MachOHeaderReader.cpuTypes(in: data),
            [MachOCPUType.x86_64, MachOCPUType.arm64]
        )
    }

    func test_fatBigEndian_legacyOnly_i386_and_powerpc() {
        let data = Data(
            be32(0xCAFE_BABE) + be32(2)
            + be32(i386) + pad16
            + be32(powerpc) + pad16
        )
        XCTAssertEqual(MachOHeaderReader.cpuTypes(in: data), [i386, powerpc])
    }

    func test_fat64_singleSlice() {
        // FAT_MAGIC_64 uses 32-byte arch entries (cputype + 28 bytes).
        let data = Data(be32(0xCAFE_BABF) + be32(1) + be32(MachOCPUType.x86_64) + pad28)
        XCTAssertEqual(MachOHeaderReader.cpuTypes(in: data), [MachOCPUType.x86_64])
    }

    // MARK: - Non-Mach-O / malformed

    func test_unrecognizedMagic_returnsNil() {
        let data = Data([0x50, 0x4B, 0x03, 0x04, 0x00, 0x00, 0x00, 0x00]) // "PK.." (a zip)
        XCTAssertNil(MachOHeaderReader.cpuTypes(in: data))
    }

    func test_tooShort_returnsNil() {
        XCTAssertNil(MachOHeaderReader.cpuTypes(in: Data([0xCF, 0xFA])))
    }

    func test_fatWithAbsurdArchCount_returnsNil() {
        let data = Data(be32(0xCAFE_BABE) + be32(9999))
        XCTAssertNil(MachOHeaderReader.cpuTypes(in: data),
                     "An implausible nfat_arch must be rejected, not trusted")
    }

    // MARK: - Classifier

    func test_classifier_emptyIsNotUnsupported() {
        XCTAssertFalse(UnsupportedAppClassifier.isUnsupported(cpuTypes: []))
    }

    func test_classifier_runnableSlicesAreSupported() {
        XCTAssertFalse(UnsupportedAppClassifier.isUnsupported(cpuTypes: [MachOCPUType.arm64]))
        XCTAssertFalse(UnsupportedAppClassifier.isUnsupported(cpuTypes: [MachOCPUType.x86_64]))
        XCTAssertFalse(UnsupportedAppClassifier.isUnsupported(
            cpuTypes: [MachOCPUType.x86_64, MachOCPUType.arm64]
        ))
    }

    func test_classifier_legacyOnlyIsUnsupported() {
        XCTAssertTrue(UnsupportedAppClassifier.isUnsupported(cpuTypes: [i386]))
        XCTAssertTrue(UnsupportedAppClassifier.isUnsupported(cpuTypes: [i386, powerpc]))
    }

    func test_classifier_anyRunnableSliceMakesItSupported() {
        // A fat binary that still ships an x86_64 slice runs under Rosetta.
        XCTAssertFalse(UnsupportedAppClassifier.isUnsupported(cpuTypes: [i386, MachOCPUType.x86_64]))
    }
}
