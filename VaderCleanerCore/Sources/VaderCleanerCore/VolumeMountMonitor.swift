// VolumeMountMonitor.swift
// Notifies when a drive is mounted and suggests cleanup when an external drive is nearly full.

import Foundation
import AppKit

/// Read-only snapshot of a mounted volume used by `VolumeMountMonitor`'s
/// decision logic. Injected so the firing rules can be unit-tested without a
/// real mount.
struct MountedVolumeInfo: Equatable {
    let name: String
    /// External/removable volumes are the ones the "overfilled drive" suggestion
    /// applies to — the boot volume has its own low-disk alert.
    let isExternal: Bool
    let freeBytes: Int64
    let totalBytes: Int64

    var freeFraction: Double {
        totalBytes > 0 ? Double(freeBytes) / Double(totalBytes) : 1
    }
}

/// Observes volume mounts via `NSWorkspace` and dispatches:
///   - a "drive connected" notification (`notifyDriveConnected`), and
///   - an "external drive almost full" suggestion (`notifyOverfilledDrives`)
///     when a freshly-mounted external volume is below `overfilledFreeFraction`.
/// The per-URL volume read is injected so `evaluate(mountedVolume:)` is testable.
@MainActor
final class VolumeMountMonitor {

    typealias VolumeReader = (URL) -> MountedVolumeInfo?

    private let preferences: PreferencesStore
    private let dispatcher: NotificationDispatching
    private let volumeReader: VolumeReader
    /// An external volume with less than this fraction free is "overfilled".
    private let overfilledFreeFraction: Double

    private var observer: NSObjectProtocol?

    init(
        preferences: PreferencesStore,
        dispatcher: NotificationDispatching,
        volumeReader: @escaping VolumeReader = VolumeMountMonitor.readVolume,
        overfilledFreeFraction: Double = 0.10
    ) {
        self.preferences = preferences
        self.dispatcher = dispatcher
        self.volumeReader = volumeReader
        self.overfilledFreeFraction = overfilledFreeFraction
    }

    /// Pure decision for a single mounted volume.
    func evaluate(mountedVolume url: URL) {
        guard let info = volumeReader(url) else { return }

        if preferences.notifyDriveConnected {
            dispatcher.sendDriveConnectedNotification(volumeName: info.name)
        }

        if preferences.notifyOverfilledDrives,
           info.isExternal,
           info.totalBytes > 0,
           info.freeFraction < overfilledFreeFraction {
            dispatcher.sendOverfilledDriveNotification(
                volumeName: info.name,
                freeBytes: info.freeBytes,
                totalBytes: info.totalBytes
            )
        }
    }

    func start() {
        stop()
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didMountNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
            MainActor.assumeIsolated { self?.evaluate(mountedVolume: url) }
        }
    }

    func stop() {
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observer = nil
    }

    /// Production volume reader: pulls name, external/removable status, and
    /// capacity from the volume's resource values.
    nonisolated static func readVolume(_ url: URL) -> MountedVolumeInfo? {
        let keys: Set<URLResourceKey> = [
            .volumeNameKey, .volumeIsInternalKey, .volumeIsRemovableKey,
            .volumeAvailableCapacityKey, .volumeTotalCapacityKey
        ]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        let isInternal = values.volumeIsInternal ?? false
        let isRemovable = values.volumeIsRemovable ?? false
        return MountedVolumeInfo(
            name: values.volumeName ?? url.lastPathComponent,
            isExternal: isRemovable || !isInternal,
            freeBytes: Int64(values.volumeAvailableCapacity ?? 0),
            totalBytes: Int64(values.volumeTotalCapacity ?? 0)
        )
    }
}
