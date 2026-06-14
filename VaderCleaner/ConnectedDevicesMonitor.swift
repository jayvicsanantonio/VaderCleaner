// ConnectedDevicesMonitor.swift
// Lists connected Bluetooth devices and ejectable volumes for the menu's Connected Devices tile, and performs volume ejection.

import Foundation
import AppKit
import IOBluetooth
import Observation

/// One entry in the menu's Connected Devices tile — a connected Bluetooth
/// device or a removable/ejectable volume.
struct ConnectedDevice: Identifiable, Equatable {
    enum Kind: Equatable {
        case bluetooth
        case volume
    }

    let id: String
    let name: String
    let kind: Kind
    /// Battery percentage when the device reports it; `nil` otherwise. Bluetooth
    /// battery has no public API, so this is typically `nil` for now.
    let batteryPercent: Int?
    /// For volumes, the mount URL to eject; `nil` for Bluetooth.
    let volumeURL: URL?
}

/// Enumerates connected Bluetooth devices and ejectable volumes, and ejects
/// volumes on request. App-scope and refreshed on demand (devices change
/// infrequently) so the menu can show them without a dedicated poll timer.
@MainActor
@Observable
final class ConnectedDevicesMonitor {

    private(set) var devices: [ConnectedDevice] = []

    init(autoRefresh: Bool = true) {
        if autoRefresh { refresh() }
    }

    /// Re-reads the Bluetooth and volume lists. Cheap enough to call when the
    /// menu opens.
    func refresh() {
        devices = bluetoothDevices() + ejectableVolumes()
    }

    /// Ejects a volume entry. No-op for Bluetooth entries or if ejection fails
    /// (the device may be busy); a failure is surfaced by the volume simply
    /// remaining in the list on the next refresh.
    func eject(_ device: ConnectedDevice) {
        guard let url = device.volumeURL else { return }
        try? NSWorkspace.shared.unmountAndEjectDevice(at: url)
        refresh()
    }

    // MARK: - Volumes

    private func ejectableVolumes() -> [ConnectedDevice] {
        let keys: Set<URLResourceKey> = [
            .volumeNameKey, .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsInternalKey
        ]
        guard let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: Array(keys),
            options: [.skipHiddenVolumes]
        ) else { return [] }

        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
            guard Self.shouldList(
                isEjectable: values.volumeIsEjectable ?? false,
                isRemovable: values.volumeIsRemovable ?? false,
                isInternal: values.volumeIsInternal ?? false
            ) else { return nil }
            return ConnectedDevice(
                id: "vol:\(url.path)",
                name: values.volumeName ?? url.lastPathComponent,
                kind: .volume,
                batteryPercent: nil,
                volumeURL: url
            )
        }
    }

    /// A volume belongs in the tile when it's user-ejectable (removable or
    /// ejectable) and not the internal boot disk. Pure so the rule is testable.
    static func shouldList(isEjectable: Bool, isRemovable: Bool, isInternal: Bool) -> Bool {
        (isEjectable || isRemovable) && !isInternal
    }

    // MARK: - Bluetooth

    private func bluetoothDevices() -> [ConnectedDevice] {
        guard let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else { return [] }
        return paired
            .filter { $0.isConnected() }
            .map { device in
                let address = device.addressString ?? UUID().uuidString
                return ConnectedDevice(
                    id: "bt:\(address)",
                    name: device.name ?? device.addressString ?? String(localized: "Bluetooth Device"),
                    kind: .bluetooth,
                    batteryPercent: nil,
                    volumeURL: nil
                )
            }
    }
}
