// SpaceLensVolumeUsage.swift
// Boot-volume capacity for the Space Lens bottom bar — reads used/total bytes and the volume name, and formats the "X of Y used" summary and usage fraction the gauge draws.

import Foundation

/// Disk-capacity snapshot for the Space Lens footer gauge. Plain value type so
/// the bottom bar can be previewed and tested with fixed numbers; `current()`
/// reads the live boot volume.
struct SpaceLensVolumeUsage: Equatable {

    let volumeName: String
    let usedBytes: Int64
    let totalBytes: Int64

    init(volumeName: String, usedBytes: Int64, totalBytes: Int64) {
        self.volumeName = volumeName
        self.usedBytes = usedBytes
        self.totalBytes = totalBytes
    }

    /// Used space as a fraction of total, clamped to `[0, 1]`. Returns 0 when
    /// total capacity is unknown so the gauge never divides by zero.
    var usedFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, max(0, Double(usedBytes) / Double(totalBytes)))
    }

    /// How much `extraBytes` (e.g. the current removal selection) adds on top
    /// of the used portion, as a fraction of total — used to tint the gauge's
    /// trailing segment. Clamped so the selection never reads past full.
    func selectionFraction(forSelected extraBytes: Int64) -> Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, max(0, Double(extraBytes) / Double(totalBytes)))
    }

    /// "1.3 TB of 2 TB used", using decimal (disk-marketing) units to match how
    /// the volume's capacity is advertised.
    var formattedSummary: String {
        let used = Self.formatter.string(fromByteCount: usedBytes)
        let total = Self.formatter.string(fromByteCount: totalBytes)
        return String(localized: "\(used) of \(total) used")
    }

    /// Decimal-unit byte formatter (1000-based), matching how disk capacity is
    /// labeled on the box ("2 TB"), unlike the binary formatter `DiskNode` uses
    /// for file sizes.
    private static let formatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useTB]
        formatter.countStyle = .file
        return formatter
    }()

    /// Reads the live boot-volume capacity. Mirrors
    /// `SystemStatsService.readDiskStats` — `/` is the boot volume on every
    /// macOS configuration we support. Falls back to zeroes (an empty gauge)
    /// rather than throwing when the attributes can't be read.
    static func current() -> SpaceLensVolumeUsage {
        let root = URL(fileURLWithPath: "/")
        let name = (try? root.resourceValues(forKeys: [.volumeNameKey]))?.volumeName
            ?? "Macintosh HD"

        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: "/") else {
            return SpaceLensVolumeUsage(volumeName: name, usedBytes: 0, totalBytes: 0)
        }
        let total = (attrs[.systemSize] as? NSNumber)?.int64Value ?? 0
        let free = (attrs[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        let used = total > free ? total - free : 0
        return SpaceLensVolumeUsage(volumeName: name, usedBytes: used, totalBytes: total)
    }
}
