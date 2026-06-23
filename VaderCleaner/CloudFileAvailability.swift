// CloudFileAvailability.swift
// Tells callers whether a file's bytes are present on disk, so byte-reading scans can skip iCloud files that aren't downloaded instead of triggering a slow, timeout-prone on-demand download.

import Foundation

/// Whether a file is materialized locally. Reading the bytes of an iCloud
/// "Optimize Mac Storage" placeholder forces an on-demand download that can
/// stall or time out (`Operation timed out`, errno 60) and makes image
/// decoders fail — so the byte-reading scanners (duplicate hashing, Vision
/// feature prints, thumbnails) check this first and skip files that aren't
/// already downloaded.
enum CloudFileAvailability {

    /// False only for ubiquitous (iCloud) items whose download status is not
    /// `.current` — i.e. cloud-only placeholders. Non-cloud files, and cloud
    /// files already downloaded, return true. On any error reading the
    /// resource values we assume the file is local (the read itself will
    /// surface a real failure, which the caller already tolerates).
    static func isLocallyAvailable(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey,
        ]) else {
            return true
        }
        guard values.isUbiquitousItem == true else { return true }
        return values.ubiquitousItemDownloadingStatus == .current
    }
}
